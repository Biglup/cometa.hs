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

-- | Plutus cost models keyed by raw ledger language identifier.
-- Unknown identifiers are retained. Parameter vectors preserve order and signed
-- 64-bit costs; evaluator validity is a separate concern.
--
-- @mkCostModel 0 [1, 2, 3]@ validates a three-parameter vector.
module Cometa.Protocol.CostModels
  ( CostModel,
    mkCostModel,
    languageId,
    costs,
    CostModels,
    empty,
    fromList,
    insert,
    lookup,
    toList,
    encodeCostModelCbor,
    decodeCostModelCbor,
    encodeCbor,
    encodeLanguageViews,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.CostModels (CostModel, CostModels, costs, languageId, mkCostModel)
import qualified Cometa.Internal.CostModels as Model
import qualified Cometa.Internal.ProtocolValues as Internal
import Data.ByteString (ByteString)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Word (Word8)
import Prelude hiding (lookup)

-- DEFINITIONS ----------------------------------------------------------------

-- | No configured language models.
empty :: CostModels
empty = Model.CostModels Map.empty

-- | Assemble models. Later models replace earlier models with the same language.
fromList :: [CostModel] -> CostModels
fromList = List.foldl' (flip insert) empty

-- | Replace the model for this language, preserving every other model.
insert :: CostModel -> CostModels -> CostModels
insert model (Model.CostModels models) = Model.CostModels (Map.insert (languageId model) model models)

-- | Find a model by raw language identifier, including unknown future languages.
lookup :: Word8 -> CostModels -> Maybe CostModel
lookup language (Model.CostModels models) = Map.lookup language models

-- | Models in ascending language-id order.
toList :: CostModels -> [CostModel]
toList (Model.CostModels models) = Map.elems models

-- | Encode only the ordered cost array. The language is supplied by the enclosing
-- ledger map and is deliberately absent from this encoding.
encodeCostModelCbor :: CostModel -> ByteString
encodeCostModelCbor = Internal.encodeBytes Model.encodeCostArray

-- | Decode one cost array for the supplied raw language id. Enforce signed 64-bit
-- costs and the 2048-parameter bound; reject trailing data.
decodeCostModelCbor :: Word8 -> ByteString -> Either Error CostModel
decodeCostModelCbor language = Internal.decodeBytes (Model.decodeCostArray language)

-- | Encode a ledger map in ascending language-id order.
encodeCbor :: CostModels -> ByteString
encodeCbor = Internal.encodeBytes Model.encodeCostModels

-- | Decode exactly one map. Duplicate language keys are rejected;
-- indefinite maps and arrays are accepted. Invalid values return
-- 'Cometa.Error.InvalidProtocolCbor'.
decodeCbor :: ByteString -> Either Error CostModels
decodeCbor = Internal.decodeBytes Model.decodeCostModels

-- | Encode the script-integrity language-view map for known Plutus languages
-- V1 through V4 (identifiers 0 through 3). Unknown language identifiers are
-- omitted from the script-data commitment. Supply only languages
-- actually used by the transaction; this operation does not select them or
-- validate parameter counts for execution. V1 uses the historical bytestring
-- key and bytestring-wrapped indefinite cost array, after the other languages.
-- This encoding differs from the protocol parameter map returned by 'encodeCbor'.
encodeLanguageViews :: CostModels -> ByteString
encodeLanguageViews = Internal.encodeBytes Model.encodeLanguageViews
