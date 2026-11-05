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

    -- * Arithmetic
    negate,
    difference,
    scale,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.AssetId (AssetId (Ada))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
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
