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

-- | Four-bit Shelley network identifiers, distinct from network magic.
--
-- @
-- import qualified Cometa.NetworkId as Network
--
-- network :: Network.NetworkId
-- network = Network.testnet
-- @
module Cometa.NetworkId (NetworkId, mkNetworkId, networkIdValue, mainnet, testnet) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (InvalidNetworkId))
import Data.Word (Word8)

-- TYPES ----------------------------------------------------------------------

-- | Four-bit network tag, 0 through 15. Tag 1 denotes mainnet; every other
-- tag uses the test-network Bech32 prefix. This tag is not a network magic.
-- Equality and ordering compare the number; 'Show' is diagnostic.
-- 'minBound' is 0 and 'maxBound' is 15.
newtype NetworkId = NetworkId Word8 deriving (Eq, Ord, Show)

instance Bounded NetworkId where
  minBound = NetworkId 0
  maxBound = NetworkId 15

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate a network tag. Values outside 0..15 return 'InvalidNetworkId'.
mkNetworkId :: Integer -> Either Error NetworkId
mkNetworkId value
  | value < 0 || value > 15 = Left (InvalidNetworkId value)
  | otherwise = Right (NetworkId (fromInteger value))

-- | Numeric four-bit tag.
networkIdValue :: NetworkId -> Word8
networkIdValue (NetworkId value) = value

-- | Mainnet tag 1.
mainnet :: NetworkId
mainnet = NetworkId 1

-- | Conventional test-network tag 0. Does not distinguish preview or preprod.
testnet :: NetworkId
testnet = NetworkId 0
