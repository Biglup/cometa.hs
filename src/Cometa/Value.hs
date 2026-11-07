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

-- | Immutable signed asset bundles with arbitrary-precision quantities.
-- Duplicate assets add, zero quantities disappear, and missing assets have
-- quantity zero. Signed deltas compose without overflow or clamping.
--
-- @
-- import qualified Cometa.AssetId as AssetId
-- import qualified Cometa.Value as Value
--
-- remaining :: Value.Value -> Value.Value -> Integer
-- remaining available required =
--   Value.quantity AssetId.Ada (Value.difference available required)
-- @
module Cometa.Value
  ( Value,

    -- * Construction
    singleton,
    lovelace,
    fromList,

    -- * Inspection
    toList,
    quantity,
    isZero,
    isNonNegative,
    assetCount,
    intersection,

    -- * Arithmetic
    negate,
    difference,
    scale,
    positivePart,
    negativePart,

    -- * Serialization
    encodeCbor,
    decodeCbor,
    encodeMintCbor,
    decodeMintCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.AssetId (AssetId (..))
import qualified Cometa.AssetName as Name
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.PolicyId as Policy
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Prelude hiding (negate)

-- TYPES ----------------------------------------------------------------------

-- | A finite bundle of signed asset quantities. Ada quantities count
-- lovelace; native quantities count units of the corresponding asset.
-- Equality compares quantities, ignoring absent zero entries. 'Show' is
-- diagnostic output. Signed values need not be valid transaction outputs or
-- mint quantities; those uses impose additional constraints.
newtype Value = Value (Map AssetId Integer) deriving (Eq, Show)

-- | Pointwise addition with zero results removed. Associative and commutative.
instance Semigroup Value where
  Value left <> Value right = normalized (Map.unionWith (+) left right)

-- | The empty bundle is the identity for addition.
instance Monoid Value where
  mempty = Value Map.empty

-- DEFINITIONS ----------------------------------------------------------------

-- | One asset quantity. Zero produces 'mempty'; negative quantities are retained.
singleton :: AssetId -> Integer -> Value
singleton asset amount = normalized (Map.singleton asset amount)

-- | An Ada quantity measured in lovelace. Zero produces 'mempty'; negative
-- amounts represent signed Ada deltas.
lovelace :: Integer -> Value
lovelace = singleton Ada

-- | Assemble entries by adding duplicate assets and removing zero totals.
-- Input order does not affect the resulting value.
fromList :: [(AssetId, Integer)] -> Value
fromList = normalized . Map.fromListWith (+)

-- | Nonzero entries in ascending 'AssetId' order: Ada, then policy/name bytes
-- lexicographically. This is not insertion order or CBOR map ordering.
toList :: Value -> [(AssetId, Integer)]
toList (Value amounts) = Map.toAscList amounts

-- | Quantity of the requested asset, or zero when absent.
quantity :: AssetId -> Value -> Integer
quantity asset (Value amounts) = Map.findWithDefault 0 asset amounts

-- | Negate every quantity exactly. The sum of a value and its negation is zero.
negate :: Value -> Value
negate = scale (-1)

-- | Left value minus right value, retaining negative results.
difference :: Value -> Value -> Value
difference left right = left <> negate right

-- | Multiply every quantity by an arbitrary signed scalar. Scaling by zero
-- yields 'mempty'; no quantity limit is imposed.
scale :: Integer -> Value -> Value
scale factor (Value amounts) = normalized (Map.map (factor *) amounts)

-- | Whether all quantities are zero, equivalently whether the bundle is empty.
isZero :: Value -> Bool
isZero (Value amounts) = Map.null amounts

-- | Whether every quantity is nonnegative. True for the empty bundle. This
-- inspection does not check quantity limits, minimum Ada or other output requirements.
isNonNegative :: Value -> Bool
isNonNegative (Value amounts) = all (>= 0) amounts

normalized :: Map AssetId Integer -> Value
normalized = Value . Map.filter (/= 0)

-- | Encode a standalone native value as an unsigned Ada integer, or
-- @[Ada, {policy: {name: signed quantity}}]@ when native assets are present.
-- Ada must be in 0 through 2^63-1; native quantities must fit signed 64 bits.
-- Invalid quantities return 'InvalidValueQuantity' before encoding. These are
-- serialization bounds, not transaction output validation: negative native
-- quantities are retained. Maps use canonical byte-length/lexicographic order.
-- This is fresh semantic encoding; zero entries have already been removed.
encodeCbor :: Value -> Either Error ByteString
encodeCbor value = do
  mapM_ validate (toList value)
  pure (Cbor.encode encoding)
  where
    coin = quantity Ada value
    validate (asset, amount)
      | amount > toInteger (maxBound :: Int64) = Left (InvalidValueQuantity amount)
      | amount < (if asset == Ada then 0 else toInteger (minBound :: Int64)) = Left (InvalidValueQuantity amount)
      | otherwise = Right ()
    encoding
      | assetCount value == (if coin == 0 then 0 else 1) = E.encodeInteger coin
      | otherwise = E.encodeListLen 2 <> E.encodeInteger coin <> assetsEncoding value

-- | Decode exactly one complete standalone value. Definite or indefinite arrays
-- and maps and nonminimal integers are accepted. Duplicate policies or names,
-- invalid identifiers, out-of-range quantities, wrong schemas and trailing bytes
-- return 'InvalidValueCbor'. Zero entries and empty policy maps normalize away;
-- original bytes are not retained. Ada is limited to 0 through 2^63-1.
decodeCbor :: ByteString -> Either Error Value
decodeCbor = Cbor.decodeAs InvalidValueCbor decoder
  where
    decoder = do
      token <- D.peekTokenType
      case token of
        D.TypeUInt -> lovelace <$> coinDecoder
        D.TypeUInt64 -> lovelace <$> coinDecoder
        _ -> Cbor.array 2 ((<>) . lovelace <$> coinDecoder <*> assetsDecoder)
    coinDecoder = do
      amount <- toInteger <$> D.decodeWord64
      unless (amount <= toInteger (maxBound :: Int64)) (fail "Ada exceeds signed native coin range")
      pure amount

-- | Number of distinct nonzero assets, including Ada when its quantity is
-- nonzero. Negative amounts count as present, just as positive amounts do.
assetCount :: Value -> Int
assetCount (Value amounts) = Map.size amounts

-- | Left-biased intersection: retain the left quantities for assets with
-- nonzero quantities in both bundles, regardless of sign. This includes signed
-- Ada; it does not clamp amounts or take a minimum. Results use normal asset
-- ordering. Useful for restricting a requested bundle to available asset kinds.
intersection :: Value -> Value -> Value
intersection (Value left) (Value right) = Value (Map.intersection left right)

-- | Retain strictly positive quantities, including Ada. The sum of
-- 'positivePart' and 'negativePart' recovers the original signed value.
positivePart :: Value -> Value
positivePart (Value amounts) = Value (Map.filter (> 0) amounts)

-- | Retain strictly negative quantities, including Ada, without negating them.
negativePart :: Value -> Value
negativePart (Value amounts) = Value (Map.filter (< 0) amounts)

-- | Encode a mint/burn bundle as @{policy: {name: signed quantity}}@ CBOR.
-- Native quantities must fit signed 64 bits, otherwise 'InvalidValueQuantity'.
-- Any nonzero Ada returns 'InvalidValueCbor': Ada cannot be minted. Empty
-- bundles encode an empty map. This does not validate policies or witnesses
-- against a transaction; identifiers are already validated by their types.
encodeMintCbor :: Value -> Either Error ByteString
encodeMintCbor value
  | quantity Ada value /= 0 = Left (InvalidValueCbor "Mint cannot contain Ada")
  | otherwise = do
      mapM_ valid (toList value)
      pure (Cbor.encode (assetsEncoding value))
  where
    valid (_, amount)
      | amount < toInteger (minBound :: Int64) || amount > toInteger (maxBound :: Int64) = Left (InvalidValueQuantity amount)
      | otherwise = Right ()

-- | Decode exactly one complete standalone mint/burn map. Policy and name
-- lengths, signed 64-bit quantities and duplicate keys are checked. Invalid
-- encodings or trailing bytes return 'InvalidValueCbor'. Definite/indefinite
-- maps are accepted; zero entries and empty policy maps normalize away.
decodeMintCbor :: ByteString -> Either Error Value
decodeMintCbor = Cbor.decodeAs InvalidValueCbor assetsDecoder

assetsEncoding :: Value -> E.Encoding
assetsEncoding value = E.encodeMapLen (fromIntegral (Map.size policies)) <> foldMap encodePolicy (Map.toAscList policies)
  where
    policies = Map.fromListWith (++) [(policy, [(name, amount)]) | (Native policy name, amount) <- toList value]
    encodePolicy (policy, assets) = E.encodeBytes (Policy.toBytes policy) <> E.encodeMapLen (fromIntegral (length assets)) <> foldMap encodeAsset (sortOn (\(name, _) -> (B.length (Name.toBytes name), Name.toBytes name)) assets)
    encodeAsset (name, amount) = E.encodeBytes (Name.toBytes name) <> E.encodeInteger amount

assetsDecoder :: D.Decoder s Value
assetsDecoder = do
  policies <- Cbor.entries $ do
    policy <- D.decodeBytes >>= either (fail . show) pure . Policy.fromBytes
    assets <- Cbor.entries $ do
      name <- D.decodeBytes >>= either (fail . show) pure . Name.fromBytes
      amount <- toInteger <$> D.decodeInt64
      pure (name, amount)
    unless (Set.size (Set.fromList (map fst assets)) == length assets) (fail "Duplicate asset name")
    pure (policy, assets)
  unless (Set.size (Set.fromList (map fst policies)) == length policies) (fail "Duplicate policy")
  pure (fromList [(Native policy name, amount) | (policy, assets) <- policies, (name, amount) <- assets])
