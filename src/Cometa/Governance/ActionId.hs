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

-- | Identify a governance proposal by its containing transaction and index.
-- These are standalone protocol identities; construction does not establish
-- that a proposal exists or is currently eligible for voting.
--
-- @
-- import qualified Cometa.Governance.ActionId as ActionId
-- import qualified Cometa.TransactionId as TransactionId
--
-- firstProposal :: TransactionId.TransactionId -> ActionId.ActionId
-- firstProposal transaction = ActionId.ActionId transaction 0
-- @
module Cometa.Governance.ActionId
  ( ActionId (..),
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.Governance (ActionId (..))
import qualified Cometa.Internal.Governance as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite CBOR @[transaction hash bytes, unsigned index]@ with the
-- shortest integer encoding. The index retains the full unsigned 64-bit range.
encodeCbor :: ActionId -> ByteString
encodeCbor = Internal.encodeActionId

-- | Decode exactly one complete action identifier. Both definite and indefinite
-- arrays and nonminimal integer encodings are accepted. Wrong arity, hash length,
-- non-unsigned index or trailing bytes returns
-- 'Cometa.Error.InvalidGovernanceCbor'. The result is semantic data; this
-- function does not retain the original encoding.
decodeCbor :: ByteString -> Either Error ActionId
decodeCbor = Internal.decodeActionId
