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

-- | Governance proposals and their index-sensitive ordered collections.
-- Assemble @Proposal deposit rewardAccount action anchor@ from validated values.
-- Deposit amounts are lovelace; current protocol requirements must be queried
-- separately. This module does not submit or validate transactions.
module Cometa.Governance.Proposal
  ( Proposal (..),
    Proposals,
    fromList,
    toList,
    empty,
    append,
    EncodedProposal,
    encodeCbor,
    decodeCbor,
    fromProposal,
    toProposal,
    toCbor,
    EncodedProposals,
    encodeProposals,
    decodeProposals,
    fromProposals,
    toProposals,
    proposalsCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Address.Reward (RewardAddress)
import qualified Cometa.Address.Reward as Reward
import Cometa.Error (Error)
import Cometa.Governance.Action (Action)
import qualified Cometa.Governance.Action as Action
import Cometa.Governance.Anchor (Anchor)
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Internal.ProposalCbor as Cbor
import Data.ByteString (ByteString)
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Deposit, its return account, the proposed action and mandatory metadata.
data Proposal = Proposal
  { -- | Lovelace deposited for the proposal, from zero through 2^64 - 1.
    proposalDeposit :: !Word64,
    -- | Reward account to receive the returned deposit.
    proposalReturnAccount :: !RewardAddress,
    -- | Requested governance change.
    proposalAction :: !Action,
    -- | Mandatory off-chain proposal metadata.
    proposalAnchor :: !Anchor
  }
  deriving (Eq, Show)

-- | Ordered proposals. Position determines proposal identity; duplicates and
-- empty collections are retained.
newtype Proposals = Proposals [Proposal] deriving (Eq, Show)

-- | One proposal retaining its original CBOR. Equality and ordering compare bytes.
data EncodedProposal = EncodedProposal !ByteString !Proposal deriving (Show)

instance Eq EncodedProposal where
  left == right = toCbor left == toCbor right

instance Ord EncodedProposal where
  compare left right = compare (toCbor left) (toCbor right)

-- | An ordered collection retaining exact imported bytes, including tag presence.
-- Equality and ordering compare those bytes; semantic inspection uses 'toProposals'.
data EncodedProposals = EncodedProposals !ByteString !Proposals deriving (Show)

instance Eq EncodedProposals where
  left == right = proposalsCbor left == proposalsCbor right

instance Ord EncodedProposals where
  compare left right = compare (proposalsCbor left) (proposalsCbor right)

-- DEFINITIONS ----------------------------------------------------------------

-- | Preserve all proposals in input order, including duplicates.
fromList :: [Proposal] -> Proposals
fromList = Proposals

-- | Proposals in their index order.
toList :: Proposals -> [Proposal]
toList (Proposals values) = values

-- | No proposals.
empty :: Proposals
empty = Proposals []

-- | Append without sorting or deduplication. Associative, with 'empty' as identity.
append :: Proposals -> Proposals -> Proposals
append (Proposals left) (Proposals right) = Proposals (left <> right)

-- | Fresh definite CBOR with shortest deposit encoding.
encodeCbor :: Proposal -> ByteString
encodeCbor (Proposal deposit account action anchor) =
  Cbor.encode
    ( E.encodeListLen 4
        <> E.encodeWord64 deposit
        <> E.encodeBytes (Reward.toBytes account)
        <> Cbor.raw (Action.encodeCbor action)
        <> Cbor.raw (Anchor.encodeCbor anchor)
    )

-- | Decode one complete proposal and retain exact original bytes. Malformed
-- fields, non-reward return addresses or trailing bytes return
-- 'Cometa.Error.InvalidProposalCbor'.
decodeCbor :: ByteString -> Either Error EncodedProposal
decodeCbor bytes = EncodedProposal bytes <$> Cbor.decode proposalDecoder bytes

-- | Assign fresh CBOR to a proposal.
fromProposal :: Proposal -> EncodedProposal
fromProposal value = EncodedProposal (encodeCbor value) value

-- | Inspect the proposal while retaining its encoded wrapper unchanged.
toProposal :: EncodedProposal -> Proposal
toProposal (EncodedProposal _ value) = value

-- | Exact imported bytes or fresh bytes assigned by 'fromProposal'.
toCbor :: EncodedProposal -> ByteString
toCbor (EncodedProposal bytes _) = bytes

-- | Fresh tag-258 definite array, preserving proposal order and duplicates.
encodeProposals :: Proposals -> ByteString
encodeProposals (Proposals values) =
  Cbor.encode
    (E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . encodeCbor) values)

-- | Decode a tagged or untagged collection with definite or indefinite array.
-- Order and duplicates are preserved; invalid schema returns
-- 'Cometa.Error.InvalidProposalCbor'. Exact original bytes are retained.
decodeProposals :: ByteString -> Either Error EncodedProposals
decodeProposals bytes = EncodedProposals bytes . Proposals <$> Cbor.decode (Cbor.setList proposalDecoder) bytes

-- | Assign fresh CBOR to an ordered proposal collection.
fromProposals :: Proposals -> EncodedProposals
fromProposals value = EncodedProposals (encodeProposals value) value

-- | Inspect proposals in index order without changing retained CBOR.
toProposals :: EncodedProposals -> Proposals
toProposals (EncodedProposals _ value) = value

-- | Exact imported collection CBOR, or fresh encoding from 'fromProposals'.
proposalsCbor :: EncodedProposals -> ByteString
proposalsCbor (EncodedProposals bytes _) = bytes

proposalDecoder :: D.Decoder s Proposal
proposalDecoder =
  Cbor.array
    4
    ( Proposal
        <$> D.decodeWord64
        <*> (D.decodeBytes >>= either (fail . show) pure . Reward.fromBytes)
        <*> (Action.toAction <$> Cbor.nested Action.decodeCbor)
        <*> Cbor.nested Anchor.decodeCbor
    )
