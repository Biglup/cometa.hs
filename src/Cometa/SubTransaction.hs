-- Copyright 2026 Biglup Labs
-- SPDX-License-Identifier: Apache-2.0
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
{-# LANGUAGE OverloadedStrings #-}

-- | Exact Dijkstra sub-transaction envelopes @[body,witnesses,auxiliary-data]@.
-- Their IDs hash only their own body. Editing an enclosing transaction does
-- not invalidate these independent signatures. Decoding does not establish
-- ledger validity or verify signatures and auxiliary-data commitments.
module Cometa.SubTransaction
  ( SubTransaction,
    fromBody,
    assemble,
    decodeCbor,
    encodeCbor,
    body,
    witnesses,
    auxiliaryData,
    transactionId,
    setBody,
    setBodySetEncoding,
    setAuxiliaryData,
    setWitnesses,
    addWitnesses,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Read as R
import qualified Codec.CBOR.Term as T
import Cometa.Encoding.Set (SetEncoding)
import Cometa.Error (Error (..))
import qualified Cometa.SubTransaction.Body as Body
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Witnesses as Witnesses
import Cometa.TransactionId (TransactionId)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text

-- TYPES ----------------------------------------------------------------------

-- | An immutable sub-transaction. Equality compares exact encoded bytes,
-- including its framing. 'Show' is diagnostic.
data SubTransaction
  = SubTransaction
      !Body.EncodedBody
      !Witnesses.EncodedWitnesses
      !(Maybe Auxiliary.EncodedAuxiliaryData)
      !ByteString
      !ByteString
  deriving (Show)

instance Eq SubTransaction where
  left == right = encodeCbor left == encodeCbor right

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble a definite three-field frame with empty witnesses and absent
-- auxiliary data. No balancing or ledger validation is performed.
fromBody :: Body.EncodedBody -> SubTransaction
fromBody encodedBody = assemble encodedBody (Witnesses.fromWitnesses Witnesses.empty) Nothing

-- | Assemble a definite three-field frame, retaining each supplied component's
-- exact bytes. Signature and auxiliary-data commitments are not checked.
assemble :: Body.EncodedBody -> Witnesses.EncodedWitnesses -> Maybe Auxiliary.EncodedAuxiliaryData -> SubTransaction
assemble encodedBody encodedWitnesses auxiliary =
  SubTransaction
    encodedBody
    encodedWitnesses
    auxiliary
    (ByteString.singleton 0x83)
    (maybe (ByteString.singleton 0xf6) Auxiliary.toCbor auxiliary)

-- | Decode exactly one three-field frame. Definite and indefinite framing and
-- all original child encodings are retained; malformed and trailing input fail.
decodeCbor :: ByteString -> Either Error SubTransaction
decodeCbor bytes = case R.deserialiseFromBytes parser (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidTransactionCbor (Text.pack (show failure)))
  Right (rest, result)
    | Lazy.null rest -> result
    | otherwise -> Left (InvalidTransactionCbor "Trailing sub-transaction CBOR")
  where
    parser = do
      size <- D.decodeListLenOrIndef
      unless (maybe True (== 3) size) (fail "Incorrect sub-transaction frame arity")
      (bodyBytes, start, _) <- item
      (witnessBytes, _, witnessEnd) <- item
      (auxiliaryBytes, _, _) <- item
      case size of
        Just _ -> pure ()
        Nothing -> D.decodeBreakOr >>= \ended -> unless ended (fail "Extra sub-transaction fields")
      pure $ do
        encodedBody <- Body.decodeCbor bodyBytes
        encodedWitnesses <- Witnesses.decodeCbor witnessBytes
        auxiliary <-
          if auxiliaryBytes == ByteString.singleton 0xf6
            then Right Nothing
            else Just <$> Auxiliary.decodeCbor auxiliaryBytes
        pure
          ( SubTransaction
              encodedBody
              encodedWitnesses
              auxiliary
              (ByteString.take start bytes)
              (ByteString.drop witnessEnd bytes)
          )
    item = do
      (_, start, end) <- D.decodeWithByteSpan T.decodeTerm
      pure
        ( ByteString.take (fromIntegral (end - start)) (ByteString.drop (fromIntegral start) bytes),
          fromIntegral start,
          fromIntegral end
        )

-- | Exact original bytes, with only edited components replaced.
encodeCbor :: SubTransaction -> ByteString
encodeCbor (SubTransaction encodedBody encodedWitnesses _ prefix suffix) =
  prefix <> Body.toCbor encodedBody <> Witnesses.toCbor encodedWitnesses <> suffix

-- | Body and exact hash-bearing encoding.
body :: SubTransaction -> Body.EncodedBody
body (SubTransaction value _ _ _ _) = value

-- | This sub-transaction's own witness set.
witnesses :: SubTransaction -> Witnesses.EncodedWitnesses
witnesses (SubTransaction _ value _ _ _) = value

-- | Optional exact auxiliary data.
auxiliaryData :: SubTransaction -> Maybe Auxiliary.EncodedAuxiliaryData
auxiliaryData (SubTransaction _ _ value _ _) = value

-- | BLAKE2b-256 of this sub-transaction's exact body encoding.
transactionId :: SubTransaction -> IO (Either Error TransactionId)
transactionId = Body.hash . body

-- | A semantically equal replacement is an exact no-op. A changed body clears
-- this sub-transaction's key signatures and retains its remaining witness bytes.
setBody :: Body.EncodedBody -> SubTransaction -> SubTransaction
setBody replacement transaction@(SubTransaction current encodedWitnesses auxiliary prefix suffix)
  | Body.toBody replacement == Body.toBody current = transaction
  | otherwise = SubTransaction replacement (Witnesses.removeKeyWitnesses encodedWitnesses) auxiliary prefix suffix

-- | Replace auxiliary data without changing this body or its signatures. The
-- body's auxiliary-data commitment must be updated separately with 'setBody'.
-- Equal auxiliary bytes are an exact no-op; original framing is retained.
setAuxiliaryData :: Maybe Auxiliary.EncodedAuxiliaryData -> SubTransaction -> SubTransaction
setAuxiliaryData replacement transaction@(SubTransaction encodedBody encodedWitnesses current prefix _)
  | replacement == current = transaction
  | otherwise =
      SubTransaction
        encodedBody
        encodedWitnesses
        replacement
        prefix
        (maybe (ByteString.singleton 0xf6) Auxiliary.toCbor replacement <> ending)
  where
    ending = if prefix == ByteString.singleton 0x9f then ByteString.singleton 0xff else ByteString.empty

-- | Replace witnesses without changing identity or framing. An equal
-- witness value is an exact no-op.
setWitnesses :: Witnesses.EncodedWitnesses -> SubTransaction -> SubTransaction
setWitnesses replacement transaction@(SubTransaction encodedBody current auxiliary prefix suffix)
  | Witnesses.toWitnesses replacement == Witnesses.toWitnesses current = transaction
  | otherwise = SubTransaction encodedBody replacement auxiliary prefix suffix

-- | Merge partial witnesses, failing on conflicting verification signatures.
addWitnesses :: Witnesses.EncodedWitnesses -> SubTransaction -> Either Error SubTransaction
addWitnesses additions transaction = do
  combined <- Witnesses.mergeEncoded (witnesses transaction) additions
  pure (setWitnesses combined transaction)

-- | Change one body's collection tag. Changed bytes remove this intent's key
-- and bootstrap signatures; unchanged tags and absent fields are exact no-ops.
-- Re-sign the intent and rebuild any enclosing transaction after a change.
setBodySetEncoding :: Body.SetField -> SetEncoding -> SubTransaction -> SubTransaction
setBodySetEncoding field requested transaction@(SubTransaction current encodedWitnesses auxiliary prefix suffix)
  | replacement == current = transaction
  | otherwise = SubTransaction replacement (Witnesses.removeKeyWitnesses encodedWitnesses) auxiliary prefix suffix
  where
    replacement = Body.withSetEncoding field requested current
