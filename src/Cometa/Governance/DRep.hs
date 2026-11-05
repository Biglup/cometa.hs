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

-- | Delegation targets distinguish a DRep credential from the predefined
-- always-abstain and always-no-confidence targets. Special targets cannot be
-- used as voting authorities.
--
-- @
-- import qualified Cometa.Governance.DRep as DRep
--
-- abstainingTarget :: DRep.DRep
-- abstainingTarget = DRep.AlwaysAbstain
-- @
module Cometa.Governance.DRep
  ( DRep (..),
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.Governance (DRep (..))
import qualified Cometa.Internal.Governance as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode fresh definite CBOR: @[0, key hash]@, @[1, script hash]@, @[2]@
-- (always abstain), or @[3]@ (always no confidence).
encodeCbor :: DRep -> ByteString
encodeCbor = Internal.encodeDRep

-- | Decode one complete DRep. Definite or indefinite arrays and nonminimal
-- unsigned codes are accepted. Codes, arity and 28-byte credential lengths are
-- checked; invalid input or trailing bytes returns
-- 'Cometa.Error.InvalidGovernanceCbor'. Original encoding is not retained.
decodeCbor :: ByteString -> Either Error DRep
decodeCbor = Internal.decodeDRep
