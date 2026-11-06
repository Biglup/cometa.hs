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
{-# LANGUAGE RankNTypes #-}

-- | Byron bootstrap addresses with checked payloads and checksums. Imported
-- encodings are retained exactly; construction assigns fresh CBOR and Base58.
--
-- @
-- import qualified Cometa.Address.Byron as Byron
--
-- inspectRoot text = Byron.root <$> Byron.fromText text
-- @
module Cometa.Address.Byron
  ( Address,
    Root,
    rootFromBytes,
    rootBytes,
    AddressType (..),
    Attributes,
    attributes,
    derivationPayload,
    networkMagic,
    address,
    root,
    addressType,
    addressAttributes,
    fromBytes,
    toBytes,
    fromText,
    toText,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Read as R
import qualified Codec.CBOR.Write as W
import Cometa.Error (Error (..))
import Control.Monad (foldM, replicateM, unless)
import Data.Bits (complement, shiftR, xor, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Int (Int64)
import Data.List (foldl', unfoldr)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)

-- TYPES ----------------------------------------------------------------------

-- | A 28-byte address root. Equality and ordering compare exact bytes.
newtype Root = Root ByteString deriving (Eq, Ord, Show)

-- | The authority used to spend a Byron output.
data AddressType
  = -- | Verification-key authority.
    PublicKey
  | -- | Script authority.
    Script
  | -- | Initial-distribution redemption key.
    Redeem
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Optional encrypted derivation payload and network magic. The payload is
-- at most 64 bytes; empty payloads are represented as absent. Magic ranges from
-- zero through 2^63-1. Absence identifies the main/staging network convention.
data Attributes = Attributes !(Maybe ByteString) !(Maybe Word64) deriving (Eq, Ord, Show)

-- | An address with its original checked encoding. Equality and ordering compare
-- address bytes; 'Show' is diagnostic output, not its Base58 representation.
data Address = Address !ByteString !Root !Attributes !AddressType deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import a 28-byte root without hashing; other lengths return 'InvalidByronAddress'.
rootFromBytes :: ByteString -> Either Error Root
rootFromBytes bytes
  | B.length bytes == 28 = Right (Root bytes)
  | otherwise = Left (InvalidByronAddress "Expected a 28-byte Byron root")

-- | Exact root bytes.
rootBytes :: Root -> ByteString
rootBytes (Root bytes) = bytes

-- | Validate an encrypted payload and network magic. Invalid bounds return
-- 'InvalidByronAddress'. This neither decrypts nor authenticates the payload.
attributes :: Maybe ByteString -> Maybe Word64 -> Either Error Attributes
attributes payload magic
  | maybe False ((> 64) . B.length) payload = Left (InvalidByronAddress "Derivation payload exceeds 64 bytes")
  | maybe False (> fromIntegral (maxBound :: Int64)) magic = Left (InvalidByronAddress "Network magic exceeds 2^63-1")
  | otherwise = Right (Attributes (payload >>= nonempty) magic)
  where
    nonempty bytes = if B.null bytes then Nothing else Just bytes

-- | Encrypted derivation payload, when present.
derivationPayload :: Attributes -> Maybe ByteString
derivationPayload (Attributes payload _) = payload

-- | Network magic; absence uses the main/staging network convention.
networkMagic :: Attributes -> Maybe Word64
networkMagic (Attributes _ magic) = magic

-- | Assemble an address with minimal CBOR and a checksum of the exact payload.
address :: Root -> Attributes -> AddressType -> Address
address digest attrs kind = Address bytes digest attrs kind
  where
    payload = W.toStrictByteString (E.encodeListLen 3 <> E.encodeBytes (rootBytes digest) <> encodeAttributes attrs <> E.encodeWord (fromIntegral (fromEnum kind)))
    bytes = W.toStrictByteString (E.encodeListLen 2 <> E.encodeTag 24 <> E.encodeBytes payload <> E.encodeWord32 (crc32 payload))

-- | Address root without recomputation.
root :: Address -> Root
root (Address _ value _ _) = value

-- | Spending-authority form.
addressType :: Address -> AddressType
addressType (Address _ _ _ value) = value

-- | Validated encrypted payload and network discriminator.
addressAttributes :: Address -> Attributes
addressAttributes (Address _ _ value _) = value

-- | Exact accepted address bytes, or fresh bytes assigned by 'address'.
toBytes :: Address -> ByteString
toBytes (Address bytes _ _ _) = bytes

-- | Validate complete outer and inner CBOR, tag 24, CRC32, root length, known
-- unique attributes and type. Malformed or trailing input returns
-- 'InvalidByronAddress'. Accepted nonminimal and indefinite array framing is
-- retained exactly; attribute values must each contain one complete value.
fromBytes :: ByteString -> Either Error Address
fromBytes bytes = do
  payload <- decode outer bytes
  (digest, attrs, kind) <- decode inner payload
  pure (Address bytes digest attrs kind)
  where
    outer = array 2 $ do
      tag <- D.decodeTag
      unless (tag == 24) (fail "Expected encoded-CBOR tag 24")
      payload <- D.decodeBytes
      checksum <- D.decodeWord32
      unless (checksum == crc32 payload) (fail "Byron checksum mismatch")
      pure payload
    inner = array 3 $ do
      digest <- D.decodeBytes >>= validate rootFromBytes
      attrs <- decodeAttributes
      code <- D.decodeWord
      kind <- case code of
        0 -> pure PublicKey
        1 -> pure Script
        2 -> pure Redeem
        _ -> fail "Unknown Byron address type"
      pure (digest, attrs, kind)

-- | Encode Base58 with the Bitcoin alphabet, without whitespace or a prefix.
toText :: Address -> Text
toText = encodeBase58 . toBytes

-- | Parse Base58 and validate its address/checksum. Invalid characters, empty
-- input, more than 512 characters or malformed data return 'InvalidByronAddressText'.
fromText :: Text -> Either Error Address
fromText text
  | Text.null text || Text.length text > 512 = Left InvalidByronAddressText
  | otherwise = do
      bytes <- maybe (Left InvalidByronAddressText) Right (decodeBase58 text)
      either (const (Left InvalidByronAddressText)) Right (fromBytes bytes)

encodeAttributes :: Attributes -> E.Encoding
encodeAttributes (Attributes payload magic) = E.encodeMapLen count <> field 1 E.encodeBytes payload <> field 2 E.encodeWord64 magic
  where
    count = maybe 0 (const 1) payload + maybe 0 (const 1) magic
    field key encodeValue = maybe mempty (\value -> E.encodeWord key <> E.encodeBytes (W.toStrictByteString (encodeValue value)))

decodeAttributes :: D.Decoder s Attributes
decodeAttributes = do
  size <- D.decodeMapLenOrIndef
  pairs <- entries size
  (payload, magic) <- foldM insert (Nothing, Nothing) pairs
  validate (uncurry attributes) (payload, magic)
  where
    entries (Just count) = replicateM count pair
    entries Nothing = do
      end <- D.decodeBreakOr
      if end then pure [] else (:) <$> pair <*> entries Nothing
    pair = (,) <$> D.decodeWord <*> D.decodeBytes
    insert (payload, magic) (key, bytes) = case key of
      1 | isNothing payload -> do
        value <- validate (decode D.decodeBytes) bytes
        pure (Just value, magic)
      2 | isNothing magic -> do
        value <- validate (decode D.decodeWord64) bytes
        pure (payload, Just value)
      _ -> fail "Unknown or repeated Byron attribute"

array :: Int -> D.Decoder s a -> D.Decoder s a
array expected parser = do
  size <- D.decodeListLenOrIndef
  case size of
    Just count -> unless (count == expected) (fail "Incorrect Byron array length")
    Nothing -> pure ()
  result <- parser
  case size of
    Just _ -> pure ()
    Nothing -> D.decodeBreakOr >>= \end -> unless end (fail "Extra Byron array fields")
  pure result

validate :: (a -> Either Error b) -> a -> D.Decoder s b
validate parser = either (fail . show) pure . parser

decode :: (forall s. D.Decoder s a) -> ByteString -> Either Error a
decode parser bytes = case R.deserialiseFromBytes parser (L.fromStrict bytes) of
  Left err -> Left (InvalidByronAddress (Text.pack (show err)))
  Right (rest, value)
    | L.null rest -> Right value
    | otherwise -> Left (InvalidByronAddress "Trailing Byron CBOR")

-- Reflected CRC-32/ISO-HDLC polynomial, initial/final XOR 0xffffffff.
crc32 :: ByteString -> Word32
crc32 = complement . B.foldl' step maxBound
  where
    step checksum byte = foldl' (\value _ -> bit value) (checksum `xor` fromIntegral byte) [1 :: Int .. 8]
    bit value = if value .&. 1 == 1 then (value `shiftR` 1) `xor` 0xedb88320 else value `shiftR` 1

alphabet :: String
alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

encodeBase58 :: ByteString -> Text
encodeBase58 bytes = Text.pack (replicate zeros '1' ++ reverse (unfoldr digit number))
  where
    zeros = B.length (B.takeWhile (== 0) bytes)
    number = B.foldl' (\n byte -> n * 256 + toInteger byte) 0 bytes
    digit 0 = Nothing
    digit value = do
      let (quotient, remainder) = value `divMod` 58
      character <- lookup remainder (zip [0 .. 57] alphabet)
      pure (character, quotient)

decodeBase58 :: Text -> Maybe ByteString
decodeBase58 text = do
  number <- foldM digit 0 (Text.unpack text)
  pure (B.pack (replicate zeros 0 ++ bytes number []))
  where
    zeros = Text.length (Text.takeWhile (== '1') text)
    digit value character = (value * 58 +) . toInteger <$> lookup character (zip alphabet [0 :: Int ..])
    bytes 0 result = result
    bytes value result = let (quotient, remainder) = value `divMod` 256 in bytes quotient (fromInteger remainder : result)
