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

-- | Transactions retain exact body, witnesses and outer framing. Decoding does
-- not verify signatures, script execution, auxiliary-data hashes or ledger rules.
-- Witness updates preserve the bytes used for the transaction ID. A changed body
-- removes outer verification-key and bootstrap signatures; embedded transaction
-- witnesses remain part of their own unchanged bodies.
--
-- @
-- import qualified Cometa.Transaction as Tx
--
-- reload bytes = Tx.encodeCbor <$> Tx.decodeCbor bytes
-- @
module Cometa.Transaction
  ( Transaction,
    Frame (..),
    fromBody,
    assemble,
    decodeCbor,
    encodeCbor,
    body,
    witnesses,
    frame,
    scriptValidity,
    auxiliaryData,
    hasScriptData,
    transactionId,
    setBody,
    setBodySetEncoding,
    setFee,
    setScriptValidity,
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
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Witnesses as Witnesses
import Cometa.TransactionId (TransactionId)
import Control.Monad (replicateM, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Outer transaction field order. These layouts describe representation, not
-- validity in a particular ledger era.
data Frame
  = -- | @[body,witnesses,auxiliary-data-or-null]@; script validity is true.
    Historical
  | -- | @[body,witnesses,script-validity,auxiliary-data-or-null]@.
    Mempool
  | -- | @[body,witnesses,auxiliary-data-or-null,script-validity]@.
    Block
  deriving (Eq, Ord, Show)

-- | An immutable transaction. Equality compares exact encoded representation,
-- including nonminimal encodings and definite versus indefinite framing.
-- 'Show' is diagnostic; use 'encodeCbor' for storage.
data Transaction = Transaction
  { transactionBody :: !Body.EncodedBody,
    transactionWitnesses :: !Witnesses.EncodedWitnesses,
    transactionFrame :: !Frame,
    transactionValidity :: !Bool,
    transactionAuxiliary :: !(Maybe Auxiliary.EncodedAuxiliaryData),
    transactionPrefix :: !ByteString,
    transactionSuffix :: !ByteString
  }
  deriving (Show)

instance Eq Transaction where
  left == right = encodeCbor left == encodeCbor right

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble an unsigned transaction with a definite four-field mempool frame,
-- true script validity, empty witnesses and absent auxiliary data. This does not
-- balance the body or assert ledger validity.
fromBody :: Body.EncodedBody -> Transaction
fromBody encodedBody = assemble encodedBody (Witnesses.fromWitnesses Witnesses.empty) Nothing

-- | Assemble a fresh definite mempool frame with true script validity. The body,
-- witness set and optional auxiliary data retain their supplied exact bytes.
-- This does not check signatures or the body's auxiliary-data commitment.
assemble :: Body.EncodedBody -> Witnesses.EncodedWitnesses -> Maybe Auxiliary.EncodedAuxiliaryData -> Transaction
assemble encodedBody encodedWitnesses auxiliary =
  Transaction
    encodedBody
    encodedWitnesses
    Mempool
    True
    auxiliary
    (ByteString.singleton 0x84)
    (ByteString.singleton 0xf5 <> maybe (ByteString.singleton 0xf6) Auxiliary.toCbor auxiliary)

-- | Decode exactly one historical, mempool or block frame, accepting definite
-- and indefinite arrays. Preserve every byte. Malformed, trailing, unsupported
-- or duplicate-field encodings return a structured error. No native resources
-- or secret keys are acquired.
decodeCbor :: ByteString -> Either Error Transaction
decodeCbor bytes = case R.deserialiseFromBytes (decodeFrame bytes) (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidTransactionCbor (Text.pack (show failure)))
  Right (rest, result)
    | Lazy.null rest -> result
    | otherwise -> Left (InvalidTransactionCbor "Trailing transaction CBOR")

-- | Exact transaction encoding. Updates retain unchanged component bytes and
-- the original outer array header and ending, including indefinite framing.
encodeCbor :: Transaction -> ByteString
encodeCbor transaction =
  transactionPrefix transaction
    <> Body.toCbor (body transaction)
    <> Witnesses.toCbor (witnesses transaction)
    <> transactionSuffix transaction

-- | Body with its exact identity-bearing encoding.
body :: Transaction -> Body.EncodedBody
body = transactionBody

-- | Outer witness set with its exact encoding.
witnesses :: Transaction -> Witnesses.EncodedWitnesses
witnesses = transactionWitnesses

-- | Original outer field order.
frame :: Transaction -> Frame
frame = transactionFrame

-- | Claimed script validity. Historical frames implicitly claim true.
scriptValidity :: Transaction -> Bool
scriptValidity = transactionValidity

-- | Optional auxiliary data, preserving its original encoding.
auxiliaryData :: Transaction -> Maybe Auxiliary.EncodedAuxiliaryData
auxiliaryData = transactionAuxiliary

-- | Whether the outer witness set contains at least one datum or redeemer.
-- Script bytes alone do not count, and nested transactions are inspected
-- independently. This does not run or validate a script.
hasScriptData :: Transaction -> Bool
hasScriptData transaction =
  let values = Witnesses.toWitnesses (witnesses transaction)
   in not (null (Witnesses.datums values) && null (Witnesses.redeemers values))

-- | BLAKE2b-256 of the exact body bytes, independent of witnesses and framing.
-- Native hashing failures return 'NativeError'.
transactionId :: Transaction -> IO (Either Error TransactionId)
transactionId = Body.hash . body

-- | Replace the body. A semantically equal body is an exact no-op, retaining
-- existing signatures and encodings. A changed body uses the supplied encoding
-- and removes only the outer verification-key and bootstrap witnesses. Scripts,
-- datums, redeemers, auxiliary data and nested transaction witnesses are retained.
-- The caller must recheck fees, auxiliary-data commitments and ledger validity.
setBody :: Body.EncodedBody -> Transaction -> Transaction
setBody replacement transaction
  | Body.toBody replacement == Body.toBody (body transaction) = transaction
  | otherwise =
      transaction
        { transactionBody = replacement,
          transactionWitnesses = Witnesses.removeKeyWitnesses (witnesses transaction)
        }

-- | Change the fee in lovelace, removing outer key signatures when it changes.
-- An unchanged fee preserves the complete original transaction.
setFee :: Word64 -> Transaction -> Transaction
setFee lovelace transaction =
  setBody (Body.setFeeEncoded lovelace (body transaction)) transaction

-- | Change claimed script validity without changing the body hash or witnesses.
-- A same-value update is an exact no-op. Historical frames cannot encode false:
-- setting false promotes them to mempool order, retaining definite/indefinite
-- framing and every component byte. Other frames retain their original order.
setScriptValidity :: Bool -> Transaction -> Transaction
setScriptValidity valid transaction
  | valid == scriptValidity transaction = transaction
  | otherwise =
      transaction
        { transactionValidity = valid,
          transactionFrame = if frame transaction == Historical then Mempool else frame transaction,
          transactionPrefix = if frame transaction == Historical then promotePrefix prefix else prefix,
          transactionSuffix = case frame transaction of
            Historical -> boolean <> suffix
            Mempool -> boolean <> ByteString.drop 1 suffix
            Block -> maybe (ByteString.singleton 0xf6) Auxiliary.toCbor (auxiliaryData transaction) <> boolean <> ending
        }
  where
    prefix = transactionPrefix transaction
    suffix = transactionSuffix transaction
    boolean = ByteString.singleton (if valid then 0xf5 else 0xf4)
    ending = if prefix == ByteString.singleton 0x9f then ByteString.singleton 0xff else ByteString.empty
    promotePrefix original
      | original == ByteString.singleton 0x9f = original
      | ByteString.length original == 1 = ByteString.singleton 0x84
      | otherwise = case ByteString.unsnoc original of
          Nothing -> ByteString.singleton 0x84
          Just (initial, _) -> initial <> ByteString.singleton 4

-- | Replace auxiliary data without changing the body or its key signatures.
-- This does not update the body's auxiliary-data commitment: supply a matching
-- body separately using 'setBody'. Equal auxiliary bytes are an exact no-op.
setAuxiliaryData :: Maybe Auxiliary.EncodedAuxiliaryData -> Transaction -> Transaction
setAuxiliaryData replacement transaction
  | replacement == auxiliaryData transaction = transaction
  | otherwise =
      transaction
        { transactionAuxiliary = replacement,
          transactionSuffix = case frame transaction of
            Historical -> auxiliary <> ending
            Mempool -> boolean <> auxiliary <> ending
            Block -> auxiliary <> boolean <> ending
        }
  where
    auxiliary = maybe (ByteString.singleton 0xf6) Auxiliary.toCbor replacement
    boolean = ByteString.singleton (if scriptValidity transaction then 0xf5 else 0xf4)
    ending = if transactionPrefix transaction == ByteString.singleton 0x9f then ByteString.singleton 0xff else ByteString.empty

-- | Replace the outer witness set without changing the body, its hash or any
-- framing bytes. An equal witness value preserves the original encoding.
setWitnesses :: Witnesses.EncodedWitnesses -> Transaction -> Transaction
setWitnesses replacement transaction
  | Witnesses.toWitnesses replacement == Witnesses.toWitnesses (witnesses transaction) = transaction
  | otherwise = transaction {transactionWitnesses = replacement}

-- | Merge partial witnesses into the outer set. Conflicting signatures for the
-- same verification key fail. Unchanged body and nested witness bytes remain
-- exact; no signature verification or script evaluation occurs.
addWitnesses :: Witnesses.EncodedWitnesses -> Transaction -> Either Error Transaction
addWitnesses additions transaction = do
  combined <- Witnesses.mergeEncoded (witnesses transaction) additions
  pure (setWitnesses combined transaction)

-- The spans come from the original immutable input. Parsing a term only locates
-- its end; component decoders validate their schema against the exact slice.
decodeFrame :: ByteString -> D.Decoder s (Either Error Transaction)
decodeFrame bytes = do
  size <- D.decodeListLenOrIndef
  fields <- case size of
    Just count -> do
      unless (count == 3 || count == 4) (fail "Incorrect transaction frame arity")
      replicateM count item
    Nothing -> indefinite
  pure $ case fields of
    [(bodyBytes, start, _), (witnessBytes, _, witnessEnd), (third, _, _)] ->
      assembleDecoded Historical True bodyBytes witnessBytes third start witnessEnd
    [(bodyBytes, start, _), (witnessBytes, _, witnessEnd), (third, _, _), (fourth, _, _)]
      | third == boolBytes True || third == boolBytes False ->
          assembleDecoded Mempool (third == boolBytes True) bodyBytes witnessBytes fourth start witnessEnd
      | fourth == boolBytes True || fourth == boolBytes False ->
          assembleDecoded Block (fourth == boolBytes True) bodyBytes witnessBytes third start witnessEnd
    _ -> Left (InvalidTransactionCbor "Invalid transaction frame")
  where
    item = do
      (_, start, end) <- D.decodeWithByteSpan T.decodeTerm
      let value = ByteString.take (fromIntegral (end - start)) (ByteString.drop (fromIntegral start) bytes)
      pure (value, fromIntegral start, fromIntegral end)
    indefinite = do
      ended <- D.decodeBreakOr
      if ended
        then pure []
        else do
          first <- item
          remaining <- indefinite
          pure (first : remaining)
    assembleDecoded layout valid bodyBytes witnessBytes auxiliaryBytes start witnessEnd = do
      encodedBody <- Body.decodeCbor bodyBytes
      encodedWitnesses <- Witnesses.decodeCbor witnessBytes
      auxiliary <-
        if auxiliaryBytes == ByteString.singleton 0xf6
          then Right Nothing
          else Just <$> Auxiliary.decodeCbor auxiliaryBytes
      pure
        ( Transaction
            encodedBody
            encodedWitnesses
            layout
            valid
            auxiliary
            (ByteString.take start bytes)
            (ByteString.drop witnessEnd bytes)
        )
    boolBytes valid = ByteString.singleton (if valid then 0xf5 else 0xf4)

-- | Change a present body's collection tag, retaining unrelated field bytes.
-- An encoding change removes outer key/bootstrap signatures even when the body
-- has the same semantic values. Absent fields and unchanged tags are exact no-ops.
-- Recheck fees and protocol encoding requirements before signing again.
setBodySetEncoding :: Body.SetField -> SetEncoding -> Transaction -> Transaction
setBodySetEncoding field requested transaction
  | replacement == body transaction = transaction
  | otherwise = transaction {transactionBody = replacement, transactionWitnesses = Witnesses.removeKeyWitnesses (witnesses transaction)}
  where
    replacement = Body.withSetEncoding field requested (body transaction)
