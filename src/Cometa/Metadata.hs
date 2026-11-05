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

-- | Validated transaction metadata. Nested maps preserve pair order and duplicate
-- keys. Transaction labels are unique unsigned 64-bit numbers. Imported encodings
-- remain exact until the caller explicitly encodes their semantic view again.
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- import Cometa.Error (Error)
-- import qualified Cometa.Metadata as Metadata
--
-- message :: Either Error Metadata.Metadata
-- message = Metadata.singleton 674 . Metadata.list . pure <$> Metadata.mkText "hello"
-- @
module Cometa.Metadata
  ( -- * Nested values
    Metadatum,
    View (..),
    mkInteger,
    mkBytes,
    mkText,
    list,
    map,
    view,

    -- * Transaction labels
    Metadata,
    singleton,
    mkMetadata,
    toList,
    lookup,

    -- * CBOR and encoding identity
    EncodedMetadata,
    EncodedMetadatum,
    encodeCbor,
    decodeCbor,
    toCbor,
    toMetadata,
    encodeMetadatumCbor,
    decodeMetadatumCbor,
    toMetadatumCbor,
    toMetadatum,

    -- * Detailed JSON
    toDetailedJson,
    fromDetailedJson,
    metadatumToDetailedJson,
    metadatumFromDetailedJson,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Write (toStrictByteString)
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import Control.Monad (replicateM)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Foldable
import qualified Data.Map.Strict as Map
import Data.Scientific (Scientific, base10Exponent, coefficient)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Text.Read (readMaybe)
import Prelude hiding (lookup, map)
import qualified Prelude

-- TYPES ----------------------------------------------------------------------

-- | A metadata value whose integers fit primitive CBOR and whose byte/text
-- strings contain at most 64 bytes. Equality compares values and nested ordering.
newtype Metadatum = Metadatum View deriving (Eq, Show)

-- | A read-only view. Constructing a view cannot bypass 'Metadatum' validation.
data View
  = -- | A primitive CBOR integer in the inclusive range @-2^64 .. 2^64-1@.
    IntegerValue Integer
  | -- | Zero through 64 arbitrary bytes.
    BytesValue ByteString
  | -- | Text containing at most 64 UTF-8 bytes, without normalization.
    TextValue Text
  | -- | An ordered list of validated values.
    ListValue [Metadatum]
  | -- | Ordered key/value pairs; duplicate keys are preserved.
    MapValue [(Metadatum, Metadatum)]
  deriving (Eq, Show)

-- | Unique labels. Equality ignores insertion order. Combining values is
-- left-biased on duplicate labels, with empty metadata as identity.
newtype Metadata = Metadata (Map.Map Word64 Metadatum) deriving (Eq, Show)

instance Semigroup Metadata where
  Metadata left <> Metadata right = Metadata (Map.union left right)

instance Monoid Metadata where
  mempty = Metadata Map.empty

-- | Validated metadata plus its original bytes. Equality compares exact bytes.
data EncodedMetadata = EncodedMetadata ByteString Metadata deriving (Show)

instance Eq EncodedMetadata where
  EncodedMetadata a _ == EncodedMetadata b _ = a == b

-- | Validated metadatum plus its original bytes. Equality compares exact bytes.
data EncodedMetadatum = EncodedMetadatum ByteString Metadatum deriving (Show)

instance Eq EncodedMetadatum where
  EncodedMetadatum a _ == EncodedMetadatum b _ = a == b

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate the inclusive range @-2^64 .. 2^64-1@. Tagged bignums are excluded.
mkInteger :: Integer -> Either Error Metadatum
mkInteger n
  | n < negate (2 ^ (64 :: Int)) || n >= 2 ^ (64 :: Int) = Left (InvalidMetadataInteger n)
  | otherwise = Right (Metadatum (IntegerValue n))

-- | Validate a byte string of 0 through 64 bytes.
mkBytes :: ByteString -> Either Error Metadatum
mkBytes b
  | ByteString.length b > 64 = Left (InvalidMetadataBytesLength (ByteString.length b))
  | otherwise = Right (Metadatum (BytesValue b))

-- | Validate at most 64 UTF-8 bytes; no Unicode normalization is performed.
mkText :: Text -> Either Error Metadatum
mkText t
  | size > 64 = Left (InvalidMetadataTextLength size)
  | otherwise = Right (Metadatum (TextValue t))
  where
    size = ByteString.length (Text.encodeUtf8 t)

-- | Assemble a list, preserving order. Empty lists are valid.
list :: [Metadatum] -> Metadatum
list = Metadatum . ListValue

-- | Assemble a map, preserving pair order and duplicate keys. Empty maps are valid.
map :: [(Metadatum, Metadatum)] -> Metadatum
map = Metadatum . MapValue

-- | Inspect a value without validation or effects.
view :: Metadatum -> View
view (Metadatum v) = v

-- | Assemble one transaction label and its validated value.
singleton :: Word64 -> Metadatum -> Metadata
singleton label value = Metadata (Map.singleton label value)

-- | Validate label uniqueness; duplicate labels return 'DuplicateMetadataLabel'.
mkMetadata :: [(Word64, Metadatum)] -> Either Error Metadata
mkMetadata = go Map.empty
  where
    go values [] = Right (Metadata values)
    go values ((label, value) : rest)
      | Map.member label values = Left (DuplicateMetadataLabel label)
      | otherwise = go (Map.insert label value values) rest

-- | Inspect entries in ascending numeric label order.
toList :: Metadata -> [(Word64, Metadatum)]
toList (Metadata m) = Map.toAscList m

-- | Find a label; missing labels are ordinary absence.
lookup :: Word64 -> Metadata -> Maybe Metadatum
lookup key (Metadata m) = Map.lookup key m

-- | Encode a semantic value with minimal integers and definite strings and
-- collections. Labels are ascending; nested map order is preserved. This is
-- normalization, not a claim of canonical sorting of arbitrary metadata keys.
encodeCbor :: Metadata -> ByteString
encodeCbor metadata = toStrictByteString (Encode.encodeMapLen (fromIntegral (length entries)) <> foldMap encodeEntry entries)
  where
    entries = Cometa.Metadata.toList metadata
    encodeEntry (label, value) = Encode.encodeWord64 label <> encodeValue value

-- | Decode exactly one metadata map. Rejects duplicate labels, trailing input,
-- invalid UTF-8, unsupported CBOR types, and out-of-bound values. Definite and
-- indefinite collections and strings are accepted; original bytes are retained.
decodeCbor :: ByteString -> Either Error EncodedMetadata
decodeCbor bytes = do
  entries <- decodeFull (decodeCollection Decode.decodeMapLenOrIndef ((,) <$> Decode.decodeWord64 <*> decodeValue)) bytes
  EncodedMetadata bytes <$> mkMetadata entries

-- | Retrieve the exact imported bytes without normalization.
toCbor :: EncodedMetadata -> ByteString
toCbor (EncodedMetadata bytes _) = bytes

-- | Inspect the semantic metadata view; encoding it again explicitly normalizes.
toMetadata :: EncodedMetadata -> Metadata
toMetadata (EncodedMetadata _ metadata) = metadata

-- | Encode a metadatum with minimal integers and definite strings/collections.
-- Map pair order and duplicate keys are preserved.
encodeMetadatumCbor :: Metadatum -> ByteString
encodeMetadatumCbor = toStrictByteString . encodeValue

-- | Decode one bounded metadatum, preserving exact bytes. The same restrictions
-- as 'decodeCbor' apply.
decodeMetadatumCbor :: ByteString -> Either Error EncodedMetadatum
decodeMetadatumCbor bytes = EncodedMetadatum bytes <$> decodeFull decodeValue bytes

-- | Retrieve exact imported metadatum bytes.
toMetadatumCbor :: EncodedMetadatum -> ByteString
toMetadatumCbor (EncodedMetadatum bytes _) = bytes

-- | Retrieve the validated semantic metadatum.
toMetadatum :: EncodedMetadatum -> Metadatum
toMetadatum (EncodedMetadatum _ value) = value

encodeValue :: Metadatum -> Encode.Encoding
encodeValue (Metadatum value) = case value of
  IntegerValue n -> Encode.encodeInteger n
  BytesValue b -> Encode.encodeBytes b
  TextValue t -> Encode.encodeString t
  ListValue xs -> Encode.encodeListLen (fromIntegral (length xs)) <> foldMap encodeValue xs
  MapValue xs -> Encode.encodeMapLen (fromIntegral (length xs)) <> foldMap (\(k, v) -> encodeValue k <> encodeValue v) xs

decodeFull :: (forall s. Decode.Decoder s a) -> ByteString -> Either Error a
decodeFull decoder bytes = case deserialiseFromBytes decoder (LazyByteString.fromStrict bytes) of
  Left _ -> Left (InvalidMetadataCbor "invalid metadata encoding")
  Right (rest, value)
    | LazyByteString.null rest -> Right value
    | otherwise -> Left (InvalidMetadataCbor "trailing input")

decodeValue :: Decode.Decoder s Metadatum
decodeValue = do
  token <- Decode.peekTokenType
  case token of
    Decode.TypeUInt -> integer
    Decode.TypeUInt64 -> integer
    Decode.TypeNInt -> integer
    Decode.TypeNInt64 -> integer
    Decode.TypeBytes -> Decode.decodeBytes >>= checked . mkBytes
    Decode.TypeBytesIndef -> Decode.decodeBytesIndef >> boundedChunks Decode.decodeBytes ByteString.length ByteString.concat >>= checked . mkBytes
    Decode.TypeString -> Decode.decodeString >>= checked . mkText
    Decode.TypeStringIndef -> Decode.decodeStringIndef >> boundedChunks Decode.decodeString (ByteString.length . Text.encodeUtf8) Text.concat >>= checked . mkText
    Decode.TypeListLen -> array
    Decode.TypeListLen64 -> array
    Decode.TypeListLenIndef -> array
    Decode.TypeMapLen -> pairs
    Decode.TypeMapLen64 -> pairs
    Decode.TypeMapLenIndef -> pairs
    _ -> fail "unsupported metadata type"
  where
    integer = Decode.decodeInteger >>= checked . mkInteger
    array = list <$> decodeCollection Decode.decodeListLenOrIndef decodeValue
    pairs = Cometa.Metadata.map <$> decodeCollection Decode.decodeMapLenOrIndef ((,) <$> decodeValue <*> decodeValue)

checked :: Either Error a -> Decode.Decoder s a
checked = either (const (fail "metadata value outside bounds")) pure

decodeCollection :: Decode.Decoder s (Maybe Int) -> Decode.Decoder s a -> Decode.Decoder s [a]
decodeCollection start item = do
  count <- start
  case count of
    Just n -> replicateM n item
    Nothing -> chunks item id

chunks :: Decode.Decoder s a -> ([a] -> b) -> Decode.Decoder s b
chunks item assemble = go []
  where
    go acc = do
      end <- Decode.decodeBreakOr
      if end then pure (assemble (reverse acc)) else item >>= \value -> go (value : acc)

-- Reject accumulated overlength strings before retaining further chunks.
boundedChunks :: Decode.Decoder s a -> (a -> Int) -> ([a] -> b) -> Decode.Decoder s b
boundedChunks item size assemble = go 0 []
  where
    go used acc = do
      end <- Decode.decodeBreakOr
      if end
        then pure (assemble (reverse acc))
        else do
          value <- item
          let next = used + size value
          if next > 64 then fail "metadata string outside bounds" else go next (value : acc)

-- | Lossless cardano-api detailed-schema JSON: top-level object keys are decimal
-- labels. This is distinct from CIP-116 inspector JSON. JSON object key order is
-- insignificant; nested map pair arrays preserve order and duplicates.
toDetailedJson :: Metadata -> Value
toDetailedJson = Object . KeyMap.fromList . Prelude.map (\(k, v) -> (Key.fromText (Text.pack (show k)), metadatumToDetailedJson v)) . Cometa.Metadata.toList

-- | Import detailed-schema JSON, validating labels and every leaf. Labels must
-- be canonical unsigned decimal strings, without leading zeros except zero.
fromDetailedJson :: Value -> Either Error Metadata
fromDetailedJson (Object values) = traverse entry (KeyMap.toList values) >>= mkMetadata
  where
    entry (key, value) = do
      let label = Key.toText key
      n <- maybe (Left (InvalidMetadataJson "invalid metadata label")) Right (readMaybe (Text.unpack label) :: Maybe Word64)
      if Text.pack (show n) /= label
        then Left (InvalidMetadataJson "noncanonical metadata label")
        else (,) n <$> metadatumFromDetailedJson value
fromDetailedJson _ = Left (InvalidMetadataJson "metadata must be an object")

-- | Convert every metadatum constructor without loss. Shapes are @{"int":n}@,
-- @{"bytes":"hex"}@, @{"string":"text"}@, @{"list":[...]}@ and
-- @{"map":[{"k":...,"v":...}]}@. Hex is lowercase without a prefix.
metadatumToDetailedJson :: Metadatum -> Value
metadatumToDetailedJson (Metadatum value) = case value of
  IntegerValue n -> object ["int" .= n]
  BytesValue b -> object ["bytes" .= Hex.encodeHex b]
  TextValue t -> object ["string" .= t]
  ListValue xs -> object ["list" .= Prelude.map metadatumToDetailedJson xs]
  MapValue xs -> object ["map" .= Prelude.map (\(k, v) -> object ["k" .= metadatumToDetailedJson k, "v" .= metadatumToDetailedJson v]) xs]

-- | Validate a detailed-schema metadatum. Integers remain exact; fractional
-- numbers, unsupported shapes, invalid hex and overlong strings fail.
metadatumFromDetailedJson :: Value -> Either Error Metadatum
metadatumFromDetailedJson = go
  where
    go :: Value -> Either Error Metadatum
    go (Object fields) = case KeyMap.toList fields of
      [("int", Number n)] -> scientificInteger n >>= mkInteger
      [("bytes", String s)] -> maybe (bad "invalid metadata hex") mkBytes (Hex.decodeHex s)
      [("string", String s)] -> mkText s
      [("list", Array xs)] -> list <$> traverse go (Data.Foldable.toList xs)
      [("map", Array xs)] -> Cometa.Metadata.map <$> traverse pair (Data.Foldable.toList xs)
      _ -> bad "invalid detailed metadata shape"
    go _ = bad "detailed metadata must be an object"
    pair (Object fields)
      | KeyMap.size fields == 2, Just k <- KeyMap.lookup "k" fields, Just v <- KeyMap.lookup "v" fields = (,) <$> go k <*> go v
    pair _ = bad "metadata map pair requires k and v"
    bad = Left . InvalidMetadataJson

-- Convert without negating an Int exponent or constructing an enormous power.
-- Negative exponents are consumed only while the coefficient has trailing zeros.
scientificInteger :: Scientific -> Either Error Integer
scientificInteger number
  | coefficientValue == 0 = Right 0
  | decimalExponent >= 0 =
      if decimalExponent > 19 then invalid else Right (coefficientValue * 10 ^ decimalExponent)
  | otherwise = divide (negate (toInteger decimalExponent)) coefficientValue
  where
    coefficientValue = coefficient number
    decimalExponent = base10Exponent number
    invalid = Left (InvalidMetadataJson "metadata integer required or outside bounds")
    divide 0 value = Right value
    divide remaining value = case quotRem value 10 of
      (next, 0) -> divide (remaining - 1) next
      _ -> invalid
