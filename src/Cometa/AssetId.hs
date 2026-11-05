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

-- | Ada and native assets with validated policy and name components.
--
-- @
-- import qualified Cometa.AssetId as AssetId
-- import qualified Cometa.AssetName as AssetName
-- import qualified Cometa.PolicyId as PolicyId
--
-- unnamedToken :: PolicyId.PolicyId -> AssetId.AssetId
-- unnamedToken policy = AssetId.Native policy AssetName.empty
-- @
module Cometa.AssetId (AssetId (..)) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.AssetName (AssetName)
import Cometa.PolicyId (PolicyId)

-- TYPES ----------------------------------------------------------------------

-- | An asset's identity. Ordering places Ada first, then compares native policy
-- bytes and name bytes lexicographically. 'Show' is diagnostic output.
data AssetId
  = -- | Ada; its quantity is measured in lovelace (one millionth of an Ada).
    Ada
  | -- | A native asset, identified by policy and exact name bytes. An empty
    -- name under a policy is a native asset, distinct from Ada.
    Native !PolicyId !AssetName
  deriving (Eq, Ord, Show)
