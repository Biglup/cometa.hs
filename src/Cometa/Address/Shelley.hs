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

-- | Base, enterprise and pointer payment addresses. Construction and byte conversion
-- are pure. Byron and reward addresses return 'UnsupportedAddressType' when imported as bytes.
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
    StakePointer (..),
    pointer,
    pointerRef,
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
import Data.Word (Word32, Word8)

-- TYPES ----------------------------------------------------------------------

-- | An immutable address. Equality and ordering compare form (base,
-- enterprise, pointer), network, then credentials; 'Show' is diagnostic.
data Address
  = Base !NetworkId !(Credential Payment) !(Credential Stake)
  | Enterprise !NetworkId !(Credential Payment)
  | Pointer !NetworkId !(Credential Payment) !StakePointer
  deriving (Eq, Ord, Show)

-- | Location of a stake registration. Each component is an unsigned 32-bit value.
data StakePointer = StakePointer
  { -- | Absolute slot containing the registration.
    slot :: !Word32,
    -- | Zero-based transaction index within that slot.
    transactionIndex :: !Word32,
    -- | Zero-based certificate index within that transaction.
    certificateIndex :: !Word32
  }
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble a base address from network, payment authority and stake authority,
-- in that order. Key and script credentials are supported in both positions.
base :: NetworkId -> Credential Payment -> Credential Stake -> Address
base = Base

-- | Assemble an address with payment authority and no staking rights.
enterprise :: NetworkId -> Credential Payment -> Address
enterprise = Enterprise

-- | Assemble a pointer address from payment authority and a registration location.
pointer :: NetworkId -> Credential Payment -> StakePointer -> Address
pointer = Pointer

-- | Registration location, present only in pointer addresses.
pointerRef :: Address -> Maybe StakePointer
pointerRef (Pointer _ _ location) = Just location
pointerRef _ = Nothing

-- | Network tag carried by the header.
networkId :: Address -> NetworkId
networkId address = case address of
  Base network _ _ -> network
  Enterprise network _ -> network
  Pointer network _ _ -> network

-- | Payment authority carried by every payment address.
paymentCredential :: Address -> Credential Payment
paymentCredential address = case address of
  Base _ credential _ -> credential
  Enterprise _ credential -> credential
  Pointer _ credential _ -> credential

-- | Staking authority; absent for enterprise and pointer addresses.
stakeCredential :: Address -> Maybe (Credential Stake)
stakeCredential address = case address of
  Base _ _ credential -> Just credential
  Enterprise {} -> Nothing
  Pointer {} -> Nothing

-- | Serialize exact header and credential bytes: 57 bytes for base addresses,
-- 29 for enterprise addresses, and 32–44 for pointer addresses.
toBytes :: Address -> ByteString
toBytes address = case address of
  Base network payment stake -> encode network (kind payment + 2 * kind stake) [credentialBytes payment, credentialBytes stake]
  Enterprise network payment -> encode network (6 + kind payment) [credentialBytes payment]
  Pointer network payment (StakePointer a b c) -> encode network (4 + kind payment) [credentialBytes payment, variable a, variable b, variable c]
  where
    encode network tag parts = ByteString.cons ((tag `shiftL` 4) .|. networkIdValue network) (ByteString.concat parts)

-- | Import exact bytes. Byron, reward and reserved headers return
-- 'UnsupportedAddressType'. Empty input or incorrect exact lengths return
-- 'InvalidShelleyAddress'. Pointer components must be minimally encoded, fit
-- 32 bits and consume the full input. All four-bit network tags are retained.
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
      value | value == 4 || value == 5 -> do
        credential <- decodeCredential (testBit tag 0) payment
        (a, restA) <- readVariable stake
        (b, restB) <- readVariable restA
        (c, restC) <- readVariable restB
        if ByteString.null restC
          then Right (Pointer network credential (StakePointer a b c))
          else Left InvalidShelleyAddress
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

variable :: Word32 -> ByteString
variable value = ByteString.pack (go value [])
  where
    go remaining tailBytes
      | remaining < 128 = fromIntegral remaining : tailBytes
      | otherwise = continue (remaining `shiftR` 7) [fromIntegral (remaining .&. 127)]
    continue remaining tailBytes
      | remaining < 128 = (fromIntegral remaining .|. 128) : tailBytes
      | otherwise = continue (remaining `shiftR` 7) ((fromIntegral (remaining .&. 127) .|. 128) : tailBytes)

readVariable :: ByteString -> Either Error (Word32, ByteString)
readVariable original = go (0 :: Int) 0 original
  where
    go count value bytes = case ByteString.uncons bytes of
      Nothing -> Left InvalidShelleyAddress
      Just (byte, rest)
        | count >= 5 -> Left InvalidShelleyAddress
        | value > (toInteger (maxBound :: Word32) - toInteger (byte .&. 127)) `div` 128 -> Left InvalidShelleyAddress
        | otherwise ->
            let next = value * 128 + toInteger (byte .&. 127)
             in if testBit byte 7
                  then go (count + 1) next rest
                  else
                    let result = fromInteger next
                        consumed = ByteString.length original - ByteString.length rest
                     in if ByteString.take consumed original == variable result
                          then Right (result, rest)
                          else Left InvalidShelleyAddress
