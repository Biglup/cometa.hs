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

-- | Staking reward accounts, distinct from payment addresses.
--
-- @
-- import qualified Cometa.Address.Reward as Reward
-- import qualified Cometa.Credential as Credential
-- import qualified Cometa.NetworkId as Network
--
-- rewardAccount :: Credential.Credential Credential.Stake -> Reward.RewardAddress
-- rewardAccount = Reward.fromCredential Network.testnet
-- @
module Cometa.Address.Reward
  ( RewardAddress,
    fromCredential,
    networkId,
    credential,
    fromBytes,
    toBytes,
    fromText,
    toText,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Credential (Credential (..), Stake)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.AddressText as AddressText
import Cometa.NetworkId (NetworkId)
import qualified Cometa.NetworkId as Network
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | An immutable reward account. Equality and ordering compare network then
-- credential (key before script, then hash bytes); 'Show' is diagnostic.
data RewardAddress = RewardAddress !NetworkId !(Credential Stake)
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble a reward account from its network and staking authority.
fromCredential :: NetworkId -> Credential Stake -> RewardAddress
fromCredential = RewardAddress

-- | Four-bit network tag carried by the header.
networkId :: RewardAddress -> NetworkId
networkId (RewardAddress network _) = network

-- | Staking authority controlling the rewards.
credential :: RewardAddress -> Credential Stake
credential (RewardAddress _ value) = value

-- | Exact 29-byte header and credential encoding.
toBytes :: RewardAddress -> ByteString
toBytes (RewardAddress network value) = case value of
  KeyCredential hash -> encode 14 (Credential.keyHashBytes hash)
  ScriptCredential hash -> encode 15 (Credential.scriptHashBytes hash)
  where
    encode tag = ByteString.cons ((tag `shiftL` 4) .|. Network.networkIdValue network)

-- | Import exact reward-account bytes. Non-reward headers return
-- 'UnsupportedAddressType'; empty input or incorrect exact lengths return
-- 'InvalidShelleyAddress'. All four-bit network tags are retained.
fromBytes :: ByteString -> Either Error RewardAddress
fromBytes bytes = case ByteString.uncons bytes of
  Nothing -> Left InvalidShelleyAddress
  Just (header, payload) -> do
    let tag = header `shiftR` 4
    if tag /= 14 && tag /= 15
      then Left (UnsupportedAddressType tag)
      else
        if ByteString.length payload /= 28
          then Left InvalidShelleyAddress
          else do
            network <- Network.mkNetworkId (toInteger (header .&. 15))
            authority <-
              if tag == 14
                then KeyCredential <$> Credential.keyHashFromBytes payload
                else ScriptCredential <$> Credential.scriptHashFromBytes payload
            pure (RewardAddress network authority)

-- | Encode canonical lowercase Bech32, with @stake@ for tag 1 and
-- @stake_test@ for other tags.
toText :: RewardAddress -> Text
toText address = AddressText.toText True (networkId address == Network.mainnet) (toBytes address)

-- | Parse lowercase or all-uppercase Bech32. Mixed case, non-ASCII, empty,
-- overlong (more than 120 characters), or mismatched network/form prefixes
-- return 'InvalidShelleyAddressText'. Malformed encoding or checksum returns
-- 'InvalidShelleyAddressText'; non-reward headers return 'UnsupportedAddressType';
-- incorrect exact lengths return 'InvalidShelleyAddress'.
fromText :: Text -> Either Error RewardAddress
fromText = AddressText.fromText fromBytes toText
