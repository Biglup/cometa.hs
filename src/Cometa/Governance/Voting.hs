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

-- | Assemble role-aware votes on governance actions. Validate identities once,
-- create a 'VotingProcedure' with an optional explanation, and associate it with
-- a voter/action pair. Repeated pairs fail explicitly rather than lose votes.
--
-- @
-- import qualified Cometa.Governance.ActionId as ActionId
-- import qualified Cometa.Governance.Voting as Voting
--
-- support :: Voting.Voter -> ActionId.ActionId -> Voting.VotingProcedures
-- support voter action =
--   Voting.singleton voter action (Voting.VotingProcedure Voting.Yes Nothing)
-- @
module Cometa.Governance.Voting
  ( -- * Choices and authorities
    Vote (..),
    Voter (..),
    VotingProcedure (..),
    encodeVoter,
    decodeVoter,
    encodeProcedure,
    decodeProcedure,

    -- * Unique voter/action collections
    VotingProcedures,
    empty,
    singleton,
    fromList,
    toList,
    insert,
    lookup,
    merge,

    -- * Encoding identity
    EncodedVotingProcedures,
    encodeCbor,
    decodeCbor,
    fromVotingProcedures,
    toVotingProcedures,
    toCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.Governance
  ( EncodedVotingProcedures,
    Vote (..),
    Voter (..),
    VotingProcedure (..),
    VotingProcedures,
    empty,
    fromList,
    fromVotingProcedures,
    insert,
    lookup,
    merge,
    singleton,
    toCbor,
    toList,
    toVotingProcedures,
  )
import qualified Cometa.Internal.Governance as Internal
import Data.ByteString (ByteString)
import Prelude hiding (lookup)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode a voter as definite CBOR @[kind, hash bytes]@. Kinds are 0 committee
-- key, 1 committee script, 2 DRep key, 3 DRep script, and 4 stake pool key.
encodeVoter :: Voter -> ByteString
encodeVoter = Internal.encodeVoter

-- | Decode exactly one voter, enforcing kind, arity, and 28-byte hash length.
-- Definite/indefinite arrays and nonminimal codes are accepted. Invalid input
-- or trailing bytes returns 'Cometa.Error.InvalidGovernanceCbor'. The original
-- encoding is not retained.
decodeVoter :: ByteString -> Either Error Voter
decodeVoter = Internal.decodeVoter

-- | Encode a procedure as definite CBOR @[choice, anchor or null]@, using
-- choice codes 0 (No), 1 (Yes) and 2 (Abstain).
encodeProcedure :: VotingProcedure -> ByteString
encodeProcedure = Internal.encodeProcedure

-- | Decode exactly one procedure with a validated optional anchor. Invalid
-- choice, arity, anchor, or trailing bytes returns
-- 'Cometa.Error.InvalidGovernanceCbor'. Definite/indefinite arrays and nonminimal
-- codes are accepted; original encoding is not retained.
decodeProcedure :: ByteString -> Either Error VotingProcedure
decodeProcedure = Internal.decodeProcedure

-- | Encode fresh nested maps ordered by voter kind/hash, then transaction
-- hash/index, using definite containers and shortest integers. Re-encoding
-- inspected external data can change its containing transaction identity;
-- 'toCbor' preserves the imported encoding instead.
encodeCbor :: VotingProcedures -> ByteString
encodeCbor = Internal.encodeVoting

-- | Decode exactly one nested voting map, preserving its exact input bytes.
-- Definite/indefinite containers and nonminimal encodings are accepted. Duplicate
-- voter keys, duplicate action keys within a voter, and empty inner maps are
-- rejected. Malformed CBOR, invalid schema, bounds, UTF-8, or trailing bytes
-- returns 'Cometa.Error.InvalidGovernanceCbor'.
decodeCbor :: ByteString -> Either Error EncodedVotingProcedures
decodeCbor = Internal.decodeVoting
