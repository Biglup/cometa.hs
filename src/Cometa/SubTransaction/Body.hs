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

-- | Dijkstra subtransaction bodies. Their schema contains shared transaction
-- fields but excludes fees, legacy updates, collateral, nested subtransactions
-- and starting-account-balance requirements.
--
-- @
-- minimal = body [] []
-- @
module Cometa.SubTransaction.Body
  ( Body,
    body,
    fromFields,
    fields,
    encodeCbor,
    EncodedBody,
    decodeCbor,
    fromBody,
    toBody,
    toCbor,
    hash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as Cbor
import Cometa.Internal.TransactionFields (Fields)
import qualified Cometa.Internal.TransactionFields as Fields
import Cometa.Transaction.Input (Input)
import Cometa.Transaction.Output (Output)
import Cometa.TransactionId (TransactionId)
import qualified Cometa.TransactionId as Id
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map

-- TYPES ----------------------------------------------------------------------

-- | Shared semantic fields with the subtransaction schema. Equality compares
-- fields, distinguishing absence, empty collections and embedded datum bytes.
newtype Body = Body Fields deriving (Eq, Show)

-- | Exact imported subtransaction-body encoding. Equality compares exact bytes.
data EncodedBody = EncodedBody !ByteString !Body deriving (Show)

instance Eq EncodedBody where
  left == right = toCbor left == toCbor right

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble required references and ordered outputs; all optional fields absent.
body :: [Input] -> [Output] -> Body
body inputs outputs = Body (Fields.fields inputs outputs)

-- | Assemble shared fields without introducing unsupported top-level fields.
fromFields :: Fields -> Body
fromFields = Body

-- | Inspect all shared semantic fields.
fields :: Body -> Fields
fields (Body value) = value

-- | Fresh definite body map in ascending numeric field order. Embedded datums
-- retain exact encoding; imported body identity is obtained through 'toCbor'.
encodeCbor :: Body -> Either Error ByteString
encodeCbor (Body value) = Fields.validateFields True value >> Right (Cbor.encode (E.encodeMapLen (fromIntegral (length pairs)) <> foldMap (\(key, payload) -> E.encodeWord64 key <> payload) (sortOn fst pairs)))
  where
    pairs = Fields.encodeFields value

-- | Validate context-specific fields and pair them with fresh bytes. Present
-- empty certificates, mint or guards and duplicate guard credentials return
-- 'InvalidTransactionField'.
fromBody :: Body -> Either Error EncodedBody
fromBody value = encodeCbor value >>= decodeCbor

-- | Inspect semantic fields without normalizing the exact body.
toBody :: EncodedBody -> Body
toBody (EncodedBody _ value) = value

-- | Exact ledger subtransaction-body bytes.
toCbor :: EncodedBody -> ByteString
toCbor (EncodedBody bytes _) = bytes

-- | Decode the complete subtransaction schema. Top-level-only fields and unknown
-- keys are rejected rather than dropped. Original map, set and number encodings
-- are preserved. Missing required fields and malformed nested data return errors.
decodeCbor :: ByteString -> Either Error EncodedBody
decodeCbor bytes = do
  pairs <- Cbor.decode (Cbor.mapFields bytes) bytes
  unless (all (`elem` [0, 1, 3, 4, 5, 7, 8, 9, 11, 14, 15, 18, 19, 20, 21, 22, 24, 25, 26]) (Map.keys pairs)) (Left (InvalidTransactionField "Unsupported subtransaction body key"))
  value <- Fields.decodeFields pairs
  Fields.validateFields True value
  pure (EncodedBody bytes (Body value))

-- | Native BLAKE2b-256 of exact body bytes, with native errors retained.
hash :: EncodedBody -> IO (Either Error TransactionId)
hash value = do
  result <- Blake2b.compute 32 (toCbor value)
  pure (result >>= Id.fromBytes . Blake2b.toBytes)
