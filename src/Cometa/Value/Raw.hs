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

-- | Immutable advanced value snapshots retaining native stored-state details.
-- Ordinary "Cometa.Value" is a normalized quantity bundle; this module keeps
-- explicit zero assets, repeated names and empty policy groups. These snapshots
-- are not transaction outputs and do not establish ledger validity.
--
-- @
-- import qualified Cometa.Value.Raw as Raw
--
-- emptySnapshot = Raw.mkSnapshot 0 []
-- @
module Cometa.Value.Raw
  ( Snapshot,
    mkSnapshot,
    coin,
    assets,
    fromValue,
    toValue,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.AssetId (AssetId (Ada, Native))
import Cometa.AssetName (AssetName)
import qualified Cometa.AssetName as Name
import Cometa.Error (Error (InvalidValueQuantity))
import Cometa.PolicyId (PolicyId)
import qualified Cometa.Value as Value
import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map

-- TYPES ----------------------------------------------------------------------

-- | Signed coin plus raw native-asset associations. Equality compares every
-- stored entry, including zero quantities, repeated names and empty groups.
-- Values are Haskell-owned immutable snapshots; retaining one preserves it when
-- another snapshot is assembled or converted. No cloning allocation is needed.
data Snapshot = Snapshot !Integer ![(PolicyId, [(AssetName, Integer)])]
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate signed 64-bit coin and asset quantities, returning
-- 'InvalidValueQuantity' on overflow. Policies sort by hash bytes; repeated
-- policy keys use the last supplied group. Names sort stably by byte length,
-- then bytes, retaining repeated names in their supplied tie order. Explicit
-- zeros and empty groups remain. The signed coin is raw accounting state;
-- negative coin is not a valid transaction-output amount.
mkSnapshot :: Integer -> [(PolicyId, [(AssetName, Integer)])] -> Either Error Snapshot
mkSnapshot lovelace groups = do
  bounded lovelace
  mapM_ (mapM_ (bounded . snd) . snd) groups
  pure (Snapshot lovelace [(policy, sortOn nameKey names) | (policy, names) <- Map.toAscList (Map.fromList groups)])
  where
    nameKey (name, _) = let bytes = Name.toBytes name in (B.length bytes, bytes)

-- | Signed coin quantity in lovelace, within the native signed 64-bit range.
coin :: Snapshot -> Integer
coin (Snapshot result _) = result

-- | Stored policy/name associations in the order documented by 'mkSnapshot'.
-- The returned lists retain zero quantities, repeated names and empty groups.
assets :: Snapshot -> [(PolicyId, [(AssetName, Integer)])]
assets (Snapshot _ result) = result

-- | Snapshot a normalized bundle, checking native signed 64-bit bounds. Input
-- normalization has already removed zero entries and combined repeated assets;
-- this operation cannot recover that discarded representation information.
fromValue :: Value.Value -> Either Error Snapshot
fromValue value = mkSnapshot (Value.quantity Ada value) (Map.toAscList groups)
  where
    groups = Map.fromListWith (<>) [(policy, [(name, quantity)]) | (Native policy name, quantity) <- Value.toList value]

-- | Explicitly normalize a raw snapshot into an ordinary bundle. This is lossy:
-- repeated names are added, zeros and empty groups disappear. The summed result
-- may exceed native bounds, which ordinary value encoders validate separately.
-- For any successfully snapshotted bundle, @fmap toValue (fromValue value) ==
-- Right value@. The reverse composition need not preserve a raw snapshot.
toValue :: Snapshot -> Value.Value
toValue (Snapshot lovelace groups) = Value.fromList ((Ada, lovelace) : [(Native policy name, quantity) | (policy, names) <- groups, (name, quantity) <- names])

bounded :: Integer -> Either Error ()
bounded quantity = unless (quantity >= toInteger (minBound :: Int64) && quantity <= toInteger (maxBound :: Int64)) (Left (InvalidValueQuantity quantity))
