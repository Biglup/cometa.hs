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

-- | Base and enterprise payment addresses. Construction and byte conversion
-- are pure. Pointer,
-- Byron and reward addresses return 'UnsupportedAddressType' when imported as bytes.
--
-- @
-- import qualified Cometa.Address.Shelley as Address
-- import qualified Cometa.Credential as Credential
--
-- receivingAddress :: Credential.KeyHash Credential.Payment -> Address.Address
-- receivingAddress key = Address.enterprise Address.mainnet (Credential.KeyCredential key)
-- @
module Cometa.Address.Shelley
  ( -- * Networks
    NetworkId,
    mkNetworkId,
    networkIdValue,
    mainnet,
    testnet,

    -- * Construction
    Address,
    base,
    enterprise,

    -- * Inspection
    networkId,
    paymentCredential,
    stakeCredential,

    -- * Encoding
    fromBytes,
    toBytes,
    fromText,
    toText,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Credential (Credential (..), Payment, Stake)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.AddressText as AddressText
import Cometa.NetworkId (NetworkId, mainnet, mkNetworkId, networkIdValue, testnet)
import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Data.Word (Word8)

-- TYPES ----------------------------------------------------------------------

-- | An immutable address. Equality and ordering compare form (base,
-- enterprise), network, then credentials; 'Show' is diagnostic.
data Address
  = Base !NetworkId !(Credential Payment) !(Credential Stake)
  | Enterprise !NetworkId !(Credential Payment)
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble a base address from network, payment authority and stake authority,
-- in that order. Key and script credentials are supported in both positions.
base :: NetworkId -> Credential Payment -> Credential Stake -> Address
base = Base

-- | Assemble an address with payment authority and no staking rights.
enterprise :: NetworkId -> Credential Payment -> Address
enterprise = Enterprise

-- | Network tag carried by the header.
networkId :: Address -> NetworkId
networkId address = case address of
  Base network _ _ -> network
  Enterprise network _ -> network

-- | Payment authority carried by every payment address.
paymentCredential :: Address -> Credential Payment
paymentCredential address = case address of
  Base _ credential _ -> credential
  Enterprise _ credential -> credential

-- | Staking authority; absent for enterprise addresses.
stakeCredential :: Address -> Maybe (Credential Stake)
stakeCredential address = case address of
  Base _ _ credential -> Just credential
  Enterprise {} -> Nothing

-- | Serialize exact header and credential bytes: 57 bytes for base addresses,
-- 29 for enterprise addresses.
toBytes :: Address -> ByteString
toBytes address = case address of
  Base network payment stake -> encode network (kind payment + 2 * kind stake) [credentialBytes payment, credentialBytes stake]
  Enterprise network payment -> encode network (6 + kind payment) [credentialBytes payment]
  where
    encode network tag parts = ByteString.cons ((tag `shiftL` 4) .|. networkIdValue network) (ByteString.concat parts)

-- | Import exact bytes. Pointer, Byron, reward and reserved headers return
-- 'UnsupportedAddressType'. Empty input or incorrect exact lengths return
-- 'InvalidShelleyAddress'. All four-bit network tags are retained.
fromBytes :: ByteString -> Either Error Address
fromBytes bytes = case ByteString.uncons bytes of
  Nothing -> Left InvalidShelleyAddress
  Just (header, payload) -> do
    let tag = header `shiftR` 4
        networkValue = header .&. 15
        (payment, stake) = ByteString.splitAt 28 payload
    network <- mkNetworkId (toInteger networkValue)
    case tag of
      value
        | value <= 3 ->
            if ByteString.length payload /= 56
              then Left InvalidShelleyAddress
              else Base network <$> decodeCredential (testBit tag 0) payment <*> decodeCredential (testBit tag 1) stake
      value | value == 6 || value == 7 -> Enterprise network <$> decodeCredential (testBit tag 0) payload
      _ -> Left (UnsupportedAddressType tag)
  where
    decodeCredential script payload
      | ByteString.length payload /= 28 = Left InvalidShelleyAddress
      | script = ScriptCredential <$> Credential.scriptHashFromBytes payload
      | otherwise = KeyCredential <$> Credential.keyHashFromBytes payload

-- | Encode canonical lowercase Bech32, with @addr@ for tag 1 and
-- @addr_test@ for other tags.
toText :: Address -> Text
toText address = AddressText.toText False (networkId address == mainnet) (toBytes address)

-- | Parse lowercase or all-uppercase Bech32. Mixed case, non-ASCII, empty,
-- overlong (more than 120 characters), or mismatched network/form prefixes
-- return 'InvalidShelleyAddressText'. Malformed encoding or checksum returns
-- 'InvalidShelleyAddressText'; unsupported headers return 'UnsupportedAddressType';
-- incorrect exact lengths return 'InvalidShelleyAddress'.
fromText :: Text -> Either Error Address
fromText = AddressText.fromText fromBytes toText

kind :: Credential purpose -> Word8
kind credential = case credential of
  KeyCredential _ -> 0
  ScriptCredential _ -> 1

credentialBytes :: Credential purpose -> ByteString
credentialBytes credential = case credential of
  KeyCredential hash -> Credential.keyHashBytes hash
  ScriptCredential hash -> Credential.scriptHashBytes hash
