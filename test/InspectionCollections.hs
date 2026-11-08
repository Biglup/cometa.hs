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

-- | Generated collection inspection laws with independent JSON expectations.
module InspectionCollections (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.AssetName as Name
import qualified Cometa.Crypto.Blake2b as Hash
import qualified Cometa.Inspection as Inspection
import qualified Cometa.PolicyId as Policy
import Data.Aeson (Value (String), object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import Hedgehog (Gen, Property, classify, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Collection inspection properties"
    [ testProperty "asset-entry arrays retain zero, signed bounds and stable duplicates" assetEntries,
      testProperty "policy-entry arrays retain empty groups and replace repeated policies" policyEntries,
      testProperty "object projections reject duplicate keys instead of collapsing them" duplicateObjects,
      testProperty "hash collection order is length-first and retains duplicates" hashes
    ]

assetEntries :: Property
assetEntries = property $ do
  raw <- forAll (Gen.list (Range.linear 0 20) ((,) <$> nameBytes <*> quantity))
  pairs <- traverse (\(bytes, amount) -> do name <- evalEither (Name.fromBytes bytes); pure (name, amount)) raw
  classify "empty collection" (null raw)
  classify "zero amount" (any ((== 0) . snd) raw)
  classify "negative amount" (any ((< 0) . snd) raw)
  classify "duplicate names" (Set.size (Set.fromList (map fst raw)) < length raw)
  actual <- evalIO (Inspection.policyAssetEntries pairs) >>= evalEither
  let expected = toJSON [object ["asset_name" .= Name.toHex name, "amount" .= Text.pack (show amount)] | (name, amount) <- sortOn (byteOrder . Name.toBytes . fst) pairs]
  actual === expected

policyEntries :: Property
policyEntries = property $ do
  raw <- forAll (Gen.list (Range.linear 0 12) ((,) <$> Gen.word8 (Range.linear 0 3) <*> Gen.list (Range.linear 0 6) ((,) <$> nameBytes <*> quantity)))
  groups <- traverse makeGroup raw
  classify "empty policy group" (any (null . snd) groups)
  classify "duplicate policies" (Set.size (Set.fromList (map fst groups)) < length groups)
  actual <- evalIO (Inspection.assetEntries groups) >>= evalEither
  let expected = toJSON [object ["script_hash" .= Policy.toHex policy, "assets" .= object [Key.fromText (Name.toHex name) .= Text.pack (show amount) | (name, amount) <- pairs]] | (policy, pairs) <- Map.toAscList (Map.fromList groups)]
  actual === expected
  where
    makeGroup (seed, names) = do
      policy <- evalEither (Policy.fromBytes (B.replicate 28 seed))
      entries <- traverse (\(bytes, amount) -> do name <- evalEither (Name.fromBytes bytes); pure (name, amount)) (Map.toList (Map.fromList names))
      pure (policy, entries)

duplicateObjects :: Property
duplicateObjects = property $ do
  bytes <- forAll nameBytes
  first <- forAll quantity
  second <- forAll quantity
  name <- evalEither (Name.fromBytes bytes)
  policy <- evalEither (Policy.fromBytes (B.replicate 28 0))
  let duplicates = [(name, first), (name, second)]
  evalIO (Inspection.policyAssets duplicates) >>= (=== True) . isLeft
  evalIO (Inspection.assets [(policy, duplicates)]) >>= (=== True) . isLeft
  evalIO (Inspection.assetEntries [(policy, duplicates)]) >>= (=== True) . isLeft

hashes :: Property
hashes = property $ do
  raw <- forAll (Gen.list (Range.linear 0 20) (Gen.bytes (Range.linear 1 64)))
  let supplied = raw <> take 2 raw
  values <- traverse (evalEither . Hash.fromBytes) supplied
  actual <- evalIO (Inspection.hashes values) >>= evalEither
  actual === toJSON (map (String . Hash.toHex) (sortOn (byteOrder . Hash.toBytes) values))

nameBytes :: Gen B.ByteString
nameBytes = Gen.choice [pure B.empty, pure (B.singleton 255), pure (B.pack [0, 0]), Gen.bytes (Range.linear 0 32)]

quantity :: Gen Integer
quantity = Gen.choice [pure 0, pure (toInteger (minBound :: Int64)), pure (toInteger (maxBound :: Int64)), toInteger <$> Gen.int64 Range.linearBounded]

byteOrder :: B.ByteString -> (Int, B.ByteString)
byteOrder bytes = (B.length bytes, bytes)
