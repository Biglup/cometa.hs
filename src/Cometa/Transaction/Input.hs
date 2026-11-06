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

-- | References to consumed or observed transaction outputs.
--
-- @
-- firstOutput transactionId = input transactionId 0
-- @
module Cometa.Transaction.Input (Input, input, transactionId, index, encodeCbor, decodeCbor) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Error (Error)
import qualified Cometa.Internal.TransactionCbor as Cbor
import Cometa.TransactionId (TransactionId)
import qualified Cometa.TransactionId as Id
import Data.ByteString (ByteString)
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Output identity. Ordering compares transaction hash bytes then numeric index.
-- An index occupies the native unsigned 64-bit range; assembly does not establish
-- that the referenced output exists or is spendable in a particular ledger era.
data Input = Input !TransactionId !Word64 deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Reference an output by transaction-body hash and zero-based output index.
input :: TransactionId -> Word64 -> Input
input = Input

-- | Hash of the transaction that created the output.
transactionId :: Input -> TransactionId
transactionId (Input value _) = value

-- | Zero-based output index, from zero through 2^64 - 1.
index :: Input -> Word64
index (Input _ value) = value

-- | Fresh two-element CBOR array with exact hash bytes and shortest index.
encodeCbor :: Input -> ByteString
encodeCbor (Input txId ix) = Cbor.encode (E.encodeListLen 2 <> E.encodeBytes (Id.toBytes txId) <> E.encodeWord64 ix)

-- | Decode one definite or indefinite pair, requiring a 32-byte hash and uint64
-- index. Malformed input, extra fields and trailing bytes return 'Cometa.Error.InvalidTransactionCbor'.
decodeCbor :: ByteString -> Either Error Input
decodeCbor = Cbor.decode (Cbor.array 2 parser)
  where
    parser = do
      bytes <- D.decodeBytes
      txId <- either (fail . show) pure (Id.fromBytes bytes)
      Input txId <$> D.decodeWord64
