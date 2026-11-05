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

-- | Transaction identifiers are exact 32-byte transaction-body hashes.
-- Importing an identifier does not hash or verify a transaction.
--
-- @
-- import qualified Cometa.TransactionId as TransactionId
-- import qualified Data.ByteString as ByteString
--
-- example = TransactionId.fromBytes (ByteString.replicate 32 0)
-- @
module Cometa.TransactionId
  ( TransactionId,
    fromBytes,
    toBytes,
    fromHex,
    toHex,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | A transaction-body hash. Equality and ordering compare exact bytes
-- lexicographically. 'Show' is diagnostic, not an interchange format.
newtype TransactionId = TransactionId ByteString deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import exactly 32 bytes. Other lengths return 'InvalidTransactionIdLength'
-- with the actual byte count.
fromBytes :: ByteString -> Either Error TransactionId
fromBytes bytes
  | ByteString.length bytes == 32 = Right (TransactionId bytes)
  | otherwise = Left (InvalidTransactionIdLength (ByteString.length bytes))

-- | Exact transaction hash bytes.
toBytes :: TransactionId -> ByteString
toBytes (TransactionId bytes) = bytes

-- | Import 64 ASCII hexadecimal digits, accepting either case. Invalid syntax
-- returns 'InvalidHex'; another decoded length returns 'InvalidTransactionIdLength'.
fromHex :: Text -> Either Error TransactionId
fromHex text = maybe (Left InvalidHex) fromBytes (Hex.decodeHex text)

-- | Lowercase hexadecimal without a prefix, always 64 digits.
toHex :: TransactionId -> Text
toHex = Hex.encodeHex . toBytes
