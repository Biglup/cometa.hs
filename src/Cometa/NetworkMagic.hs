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

-- | Named protocol network magics. These are full 32-bit values, distinct from
-- the four-bit Shelley address tag in "Cometa.NetworkId". Custom networks can
-- use any 'Word32'; these constants do not select a provider or a network endpoint.
module Cometa.NetworkMagic (mainnet, preprod, preview, sanchonet, name) where

-- IMPORTS --------------------------------------------------------------------

import Data.Text (Text)
import Data.Word (Word32)

-- DEFINITIONS ----------------------------------------------------------------

-- | Cardano mainnet protocol magic, 764824073.
mainnet :: Word32
mainnet = 764824073

-- | Preprod protocol magic, 1.
preprod :: Word32
preprod = 1

-- | Preview protocol magic, 2.
preview :: Word32
preview = 2

-- | SanchoNet protocol magic, 4. A protocol identifier does not imply that a
-- hosted endpoint is currently available.
sanchonet :: Word32
sanchonet = 4

-- | Lowercase name for the four known magics, or @"unknown"@ for any other
-- value. Custom magic numbers remain valid even when they have no known name.
name :: Word32 -> Text
name value
  | value == mainnet = "mainnet"
  | value == preprod = "preprod"
  | value == preview = "preview"
  | value == sanchonet = "sanchonet"
  | otherwise = "unknown"
