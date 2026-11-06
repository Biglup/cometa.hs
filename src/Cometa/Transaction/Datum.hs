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

-- | Output datum alternatives. Inline data retains exact datum bytes because
-- re-encoding a datum can change its hash.
--
-- @
-- noDatum = NoDatum
-- @
module Cometa.Transaction.Datum (Datum (..), Hash32, hashFromBytes, hashBytes) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.PlutusData (EncodedPlutusData)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B

-- TYPES ----------------------------------------------------------------------

-- | An exact 32-byte datum, script-data or auxiliary-data digest. Equality and
-- ordering compare bytes; importing does not verify how the digest was obtained.
newtype Hash32 = Hash32 ByteString deriving (Eq, Ord, Show)

-- | Output datum choice. A hash carries no witness datum; inline data carries
-- the exact encoded datum, including arbitrary map order and duplicate keys.
data Datum
  = -- | No datum is attached to the output.
    NoDatum
  | -- | Hash identifying a datum supplied separately as a witness when needed.
    DatumHash !Hash32
  | -- | Exact datum bytes embedded directly in the output.
    InlineDatum !EncodedPlutusData
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate exactly 32 digest bytes; otherwise return 'InvalidTransactionHashLength'.
hashFromBytes :: ByteString -> Either Error Hash32
hashFromBytes bytes
  | B.length bytes == 32 = Right (Hash32 bytes)
  | otherwise = Left (InvalidTransactionHashLength (B.length bytes))

-- | Exact digest bytes, always length 32.
hashBytes :: Hash32 -> ByteString
hashBytes (Hash32 bytes) = bytes
