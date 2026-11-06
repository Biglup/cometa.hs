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

-- | Signed native-range asset bundle encoding; no native references.
module Cometa.Internal.TransactionValue (encodeAssets, decodeAssets, validateOutput, validateMint) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.AssetId (AssetId (..))
import qualified Cometa.AssetName as Name
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Value as Value
import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- TYPES ----------------------------------------------------------------------

-- DEFINITIONS ----------------------------------------------------------------

validateOutput :: Value.Value -> Either Error ()
validateOutput value = mapM_ valid (Value.toList value)
  where
    valid (_, quantity)
      | quantity < 0 || quantity > toInteger (maxBound :: Int64) = Left (InvalidTransactionOutputValue quantity)
      | otherwise = Right ()

validateMint :: Value.Value -> Either Error ()
validateMint value = mapM_ valid (Value.toList value)
  where
    valid (asset, quantity)
      | asset == Ada = Left (InvalidTransactionField "Mint cannot contain Ada")
      | quantity < toInteger (minBound :: Int64) || quantity > toInteger (maxBound :: Int64) = Left (InvalidTransactionOutputValue quantity)
      | otherwise = Right ()

encodeAssets :: Value.Value -> E.Encoding
encodeAssets value = E.encodeMapLen (fromIntegral (Map.size policies)) <> foldMap encodePolicy (Map.toAscList policies)
  where
    policies = Map.fromListWith (++) [(policy, [(name, amount)]) | (Native policy name, amount) <- Value.toList value]
    encodePolicy (policy, assets) = E.encodeBytes (Policy.toBytes policy) <> E.encodeMapLen (fromIntegral (length assets)) <> foldMap (\(name, amount) -> E.encodeBytes (Name.toBytes name) <> E.encodeInteger amount) (sortOn (\(name, _) -> (B.length (Name.toBytes name), Name.toBytes name)) (Map.toAscList (Map.fromList assets)))

decodeAssets :: D.Decoder s Value.Value
decodeAssets = do
  policies <- Cbor.entries $ do
    bytes <- D.decodeBytes
    policy <- either (fail . show) pure (Policy.fromBytes bytes)
    assets <- Cbor.entries $ do
      nameBytes <- D.decodeBytes
      name <- either (fail . show) pure (Name.fromBytes nameBytes)
      amount <- D.decodeInteger
      unless (amount >= toInteger (minBound :: Int64) && amount <= toInteger (maxBound :: Int64)) (fail "Asset quantity exceeds int64")
      pure (name, amount)
    unless (Set.size (Set.fromList (map fst assets)) == length assets) (fail "Duplicate asset name")
    pure (policy, assets)
  unless (Set.size (Set.fromList (map fst policies)) == length policies) (fail "Duplicate policy")
  pure (Value.fromList [(Native policy name, amount) | (policy, assets) <- policies, (name, amount) <- assets])
