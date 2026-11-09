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

-- | Assemble Plutus script arguments and datums as immutable Haskell values.
-- Maps preserve entry order and duplicate keys. Decode external datum CBOR into
-- 'EncodedPlutusData' to preserve the bytes that determine its hash.
--
-- @
-- import qualified Cometa.PlutusData as Data
--
-- main :: IO ()
-- main = print =<< Data.hash (Data.fromData (Data.Constr 0 [Data.Integer 42]))
-- @
module Cometa.PlutusData
  ( -- * Semantic data
    PlutusData (..),

    -- * CBOR and encoding identity
    EncodedPlutusData,
    encodeCbor,
    decodeCbor,
    fromData,
    integerFromText,
    toData,
    toCbor,

    -- * Datum hash
    hash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import Cometa.Crypto.Blake2b (Blake2bHash)
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Encoding.Integer as Integer
import Cometa.Error (Error (..))
import Control.Monad (replicateM, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Semantic script data. Equality and ordering are structural: map entry order
-- and duplicates participate. Ordering follows constructor order, then payloads;
-- it does not define ledger map normalization.
data PlutusData
  = -- | Constructor alternative (0 through 2^64 - 1) and ordered fields.
    Constr Word64 [PlutusData]
  | -- | Ordered key/value pairs, including duplicate keys.
    Map [(PlutusData, PlutusData)]
  | -- | Ordered elements.
    List [PlutusData]
  | -- | An arbitrary-precision signed integer.
    Integer Integer
  | -- | Arbitrary bytes, including the empty byte string.
    Bytes ByteString
  deriving (Eq, Ord, Show)

-- | Valid script data together with its exact CBOR identity. Equality and
-- ordering compare the original encoded bytes; inspect 'toData' for semantic
-- comparison. 'Show' is diagnostic and is not an interchange format.
data EncodedPlutusData = EncodedPlutusData !ByteString !PlutusData
  deriving (Show)

instance Eq EncodedPlutusData where
  left == right = toCbor left == toCbor right

instance Ord EncodedPlutusData where
  compare left right = compare (toCbor left) (toCbor right)

-- DEFINITIONS ----------------------------------------------------------------

-- | Parse an arbitrary-precision integer using a validated native-compatible
-- radix and assemble its fresh script-data encoding. No ledger metadata bounds
-- apply. Invalid text returns 'Cometa.Error.InvalidIntegerText'.
integerFromText :: Integer.Radix -> Text -> Either Error EncodedPlutusData
integerFromText radix text = fromData . Integer <$> Integer.fromText radix text

-- | Serialize fresh semantic data with shortest integer/tag encodings, definite
-- lists and maps, and byte chunks of at most 64 bytes. Map order and duplicates
-- are retained. Re-encoding inspected external data may change its datum hash;
-- use 'toCbor' to preserve an existing encoding.
encodeCbor :: PlutusData -> ByteString
encodeCbor = Write.toStrictByteString . encodeData

-- | Decode exactly one complete datum, accepting definite and indefinite lists,
-- maps and byte strings, nonminimal integer encodings, and constructor tags
-- 121..127, 1280..1400 and 102. Each definite byte leaf/chunk must contain at
-- most 64 bytes, including bignum payloads. Invalid input or trailing bytes
-- returns 'InvalidPlutusDataCbor'. The original bytes are retained unchanged.
decodeCbor :: ByteString -> Either Error EncodedPlutusData
decodeCbor bytes = case Read.deserialiseFromBytes decodeData (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidPlutusDataCbor (Text.pack (show failure)))
  Right (remaining, value)
    | Lazy.null remaining -> Right (EncodedPlutusData bytes value)
    | otherwise -> Left (InvalidPlutusDataCbor "Trailing bytes after Plutus data")

-- | Give fresh semantic data a newly serialized encoding identity.
fromData :: PlutusData -> EncodedPlutusData
fromData value = EncodedPlutusData (encodeCbor value) value

-- | Inspect semantic data without modifying its preserved encoding.
toData :: EncodedPlutusData -> PlutusData
toData (EncodedPlutusData _ value) = value

-- | Observe the exact original encoding, or the encoding assigned by 'fromData'.
toCbor :: EncodedPlutusData -> ByteString
toCbor (EncodedPlutusData bytes _) = bytes

-- | Compute the 32-byte BLAKE2b datum digest over the exact preserved CBOR.
-- Native allocation and operation failures return 'NativeError'.
hash :: EncodedPlutusData -> IO (Either Error Blake2bHash)
hash = Blake2b.compute 32 . toCbor

encodeData :: PlutusData -> Encode.Encoding
encodeData value = case value of
  Constr alternative fields
    | alternative < 7 -> Encode.encodeTag64 (121 + alternative) <> encodeList fields
    | alternative < 128 -> Encode.encodeTag64 (1280 + alternative - 7) <> encodeList fields
    | otherwise -> Encode.encodeTag 102 <> Encode.encodeListLen 2 <> Encode.encodeWord64 alternative <> encodeList fields
  Map pairs -> Encode.encodeMapLen (fromIntegral (length pairs)) <> foldMap (\(key, item) -> encodeData key <> encodeData item) pairs
  List values -> encodeList values
  Integer number
    | number >= negate (2 ^ (64 :: Int)), number < 2 ^ (64 :: Int) -> Encode.encodeInteger number
    | number >= 0 -> Encode.encodeTag 2 <> encodeBytes (integerBytes number)
    | otherwise -> Encode.encodeTag 3 <> encodeBytes (integerBytes (-1 - number))
  Bytes bytes -> encodeBytes bytes

encodeList :: [PlutusData] -> Encode.Encoding
encodeList values = Encode.encodeListLen (fromIntegral (length values)) <> foldMap encodeData values

encodeBytes :: ByteString -> Encode.Encoding
encodeBytes bytes
  | ByteString.length bytes <= 64 = Encode.encodeBytes bytes
  | otherwise = Encode.encodeBytesIndef <> chunks bytes <> Encode.encodeBreak
  where
    chunks remaining
      | ByteString.null remaining = mempty
      | otherwise = let (chunk, rest) = ByteString.splitAt 64 remaining in Encode.encodeBytes chunk <> chunks rest

integerBytes :: Integer -> ByteString
integerBytes = ByteString.reverse . ByteString.unfoldr step
  where
    step 0 = Nothing
    step number = Just (fromIntegral (number `mod` 256), number `div` 256)

decodeData :: Decode.Decoder s PlutusData
decodeData = do
  token <- Decode.peekTokenType
  case token of
    Decode.TypeUInt -> Integer <$> Decode.decodeInteger
    Decode.TypeUInt64 -> Integer <$> Decode.decodeInteger
    Decode.TypeNInt -> Integer <$> Decode.decodeInteger
    Decode.TypeNInt64 -> Integer <$> Decode.decodeInteger
    Decode.TypeInteger -> decodeTagged
    Decode.TypeBytes -> Bytes <$> decodeBytes
    Decode.TypeBytesIndef -> Bytes <$> decodeBytes
    Decode.TypeListLen -> List <$> decodeList
    Decode.TypeListLen64 -> List <$> decodeList
    Decode.TypeListLenIndef -> List <$> decodeList
    Decode.TypeMapLen -> Map <$> decodeMap
    Decode.TypeMapLen64 -> Map <$> decodeMap
    Decode.TypeMapLenIndef -> Map <$> decodeMap
    Decode.TypeTag -> decodeTagged
    Decode.TypeTag64 -> decodeTagged
    _ -> fail "Expected Plutus constructor, map, list, integer or bytes"

decodeTagged :: Decode.Decoder s PlutusData
decodeTagged = do
  tag <- Decode.decodeTag64
  case tag of
    2 -> Integer . bytesInteger <$> decodeBytes
    3 -> Integer . (-1 -) . bytesInteger <$> decodeBytes
    102 -> do
      size <- Decode.decodeListLenOrIndef
      unless (isNothing size || size == Just 2) (fail "Extended constructor requires exactly two elements")
      alternative <- Decode.decodeWord64
      fields <- decodeList
      case size of
        Nothing -> do
          done <- Decode.decodeBreakOr
          unless done (fail "Extended constructor requires exactly two elements")
        Just _ -> pure ()
      pure (Constr alternative fields)
    _
      | tag >= 121 && tag <= 127 -> Constr (tag - 121) <$> decodeList
      | tag >= 1280 && tag <= 1400 -> Constr (tag - 1280 + 7) <$> decodeList
      | otherwise -> fail "Unknown Plutus constructor tag"

bytesInteger :: ByteString -> Integer
bytesInteger = ByteString.foldl' (\number byte -> number * 256 + fromIntegral byte) 0

decodeBytes :: Decode.Decoder s ByteString
decodeBytes = do
  token <- Decode.peekTokenType
  case token of
    Decode.TypeBytes -> boundedBytes
    Decode.TypeBytesIndef -> do
      Decode.decodeBytesIndef
      ByteString.concat <$> indefinite boundedBytes
    _ -> fail "Expected byte string"
  where
    boundedBytes = do
      bytes <- Decode.decodeBytes
      unless (ByteString.length bytes <= 64) (fail "Plutus byte chunk exceeds 64 bytes")
      pure bytes

decodeList :: Decode.Decoder s [PlutusData]
decodeList = do
  size <- Decode.decodeListLenOrIndef
  case size of
    Nothing -> indefinite decodeData
    Just count -> replicateM count decodeData

decodeMap :: Decode.Decoder s [(PlutusData, PlutusData)]
decodeMap = do
  size <- Decode.decodeMapLenOrIndef
  case size of
    Nothing -> indefinite pair
    Just count -> replicateM count pair
  where
    pair = (,) <$> decodeData <*> decodeData

indefinite :: Decode.Decoder s value -> Decode.Decoder s [value]
indefinite decoder = go []
  where
    go accumulated = do
      done <- Decode.decodeBreakOr
      if done
        then pure (reverse accumulated)
        else do
          value <- decoder
          go (value : accumulated)
