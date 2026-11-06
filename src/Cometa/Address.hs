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

-- | Addresses across Shelley, Byron and reward-account forms. This sum retains
-- each family's validated representation; it does not establish whether an
-- address is an admissible transaction output for a particular ledger era.
--
-- @
-- import qualified Cometa.Address as Address
--
-- normalize text = Address.toText <$> Address.fromText text
-- @
module Cometa.Address (Address (..), fromBytes, toBytes, fromText, toText) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Byron as Byron
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import Cometa.Error (Error (..))
import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text

-- TYPES ----------------------------------------------------------------------

-- | Address families. Equality and ordering compare constructors then values;
-- use 'toBytes' when serialization order is required.
data Address
  = -- | Base, enterprise or pointer payment address.
    ShelleyAddress !Shelley.Address
  | -- | Historical bootstrap address.
    ByronAddress !Byron.Address
  | -- | Reward account; assembly does not imply output admissibility.
    RewardAddress !Reward.RewardAddress
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Exact validated address bytes.
toBytes :: Address -> ByteString
toBytes (ShelleyAddress value) = Shelley.toBytes value
toBytes (ByronAddress value) = Byron.toBytes value
toBytes (RewardAddress value) = Reward.toBytes value

-- | Decode the complete address according to its header. Validation errors
-- retain the corresponding family's structured error.
fromBytes :: ByteString -> Either Error Address
fromBytes bytes = case ByteString.uncons bytes of
  Nothing -> Left InvalidShelleyAddress
  Just (header, _) -> case header `shiftR` 4 of
    kind | kind <= 7 -> ShelleyAddress <$> Shelley.fromBytes bytes
    kind | kind == 8 || kind == 9 -> ByronAddress <$> Byron.fromBytes bytes
    kind | kind == 14 || kind == 15 -> RewardAddress <$> Reward.fromBytes bytes
    kind -> Left (UnsupportedAddressType kind)

-- | Bech32 for Shelley/reward addresses and Base58 for Byron addresses.
toText :: Address -> Text
toText (ShelleyAddress value) = Shelley.toText value
toText (ByronAddress value) = Byron.toText value
toText (RewardAddress value) = Reward.toText value

-- | Decode Bech32 payment/reward forms or Base58 bootstrap addresses.
fromText :: Text -> Either Error Address
fromText text
  | Text.isPrefixOf (Text.pack "addr") lowered = ShelleyAddress <$> Shelley.fromText text
  | Text.isPrefixOf (Text.pack "stake") lowered = RewardAddress <$> Reward.fromText text
  | otherwise = ByronAddress <$> Byron.fromText text
  where
    lowered = Text.toLower text
