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

-- | Ordered cost parameter vectors, independent of evaluator validation.
module Cometa.Internal.CostModels
  ( CostModel (..),
    CostModels (..),
    mkCostModel,
    encodeCostArray,
    decodeCostArray,
    encodeCostModels,
    decodeCostModels,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import Cometa.Error (Error (InvalidCostModelLength))
import Control.Monad (replicateM)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word8)

-- TYPES ----------------------------------------------------------------------

-- | Raw ledger language id and ordered signed 64-bit costs. At most 2048 costs
-- are supported. Construction does not establish evaluator validity.
data CostModel = CostModel
  { -- | Raw ledger language identifier from 0 through 255.
    languageId :: !Word8,
    -- | Ordered signed 64-bit parameters, with at most 2048 entries.
    costs :: ![Int64]
  }
  deriving (Eq, Ord, Show)

-- | One model per language id. Equality and ordering compare ascending entries.
newtype CostModels = CostModels (Map Word8 CostModel) deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate the native vector length bound. Unknown language ids are retained.
mkCostModel :: Word8 -> [Int64] -> Either Error CostModel
mkCostModel language values
  | count > 2048 = Left (InvalidCostModelLength count)
  | otherwise = Right (CostModel language values)
  where
    count = length values

encodeCostArray :: CostModel -> Encode.Encoding
encodeCostArray (CostModel _ values) = Encode.encodeListLen (fromIntegral (length values)) <> foldMap Encode.encodeInt64 values

decodeCostArray :: Word8 -> Decode.Decoder s CostModel
decodeCostArray language = do
  count <- Decode.decodeListLenOrIndef
  values <- case count of
    Just size | size > 2048 -> fail "cost model exceeds 2048 parameters"
    Just size -> replicateM size Decode.decodeInt64
    Nothing -> indefiniteCosts 0 []
  pure (CostModel language values)
  where
    indefiniteCosts count values = do
      end <- Decode.decodeBreakOr
      if end
        then pure (reverse values)
        else
          if count >= (2048 :: Int)
            then fail "cost model exceeds 2048 parameters"
            else do
              value <- Decode.decodeInt64
              indefiniteCosts (count + 1) (value : values)

encodeCostModels :: CostModels -> Encode.Encoding
encodeCostModels (CostModels models) = Encode.encodeMapLen (fromIntegral (Map.size models)) <> foldMap encodeEntry (Map.toAscList models)
  where
    encodeEntry (language, model) = Encode.encodeWord8 language <> encodeCostArray model

decodeCostModels :: Decode.Decoder s CostModels
decodeCostModels = do
  count <- Decode.decodeMapLenOrIndef
  case count of
    Just size -> replicateM size decodeEntry >>= uniqueModels
    Nothing -> indefiniteEntries [] >>= uniqueModels
  where
    uniqueModels entries =
      let models = Map.fromList entries
       in if Map.size models == length entries then pure (CostModels models) else fail "duplicate cost model language"
    decodeEntry = do
      language <- Decode.decodeWord8
      model <- decodeCostArray language
      pure (language, model)
    indefiniteEntries entries = do
      end <- Decode.decodeBreakOr
      if end
        then pure entries
        else do
          entry <- decodeEntry
          indefiniteEntries (entry : entries)
