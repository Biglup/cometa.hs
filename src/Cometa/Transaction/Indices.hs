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

-- | Locate objects in a top-level transaction for deferred redeemers and script
-- arguments. Indices start at zero and can change when the body changes.
-- Missing objects return 'Nothing'. Nested levels remain independent.
--
-- @
-- import qualified Cometa.Transaction.Indices as Indices
--
-- spendingPosition reference transaction = Indices.findInput reference transaction
-- @
module Cometa.Transaction.Indices
  ( findInput,
    findReferenceInput,
    findOutput,
    findMintPolicy,
    findWithdrawal,
    findCertificate,
    findVote,
    findProposal,
    findRedeemer,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Address (Address)
import Cometa.Address.Reward (RewardAddress)
import Cometa.Certificate (EncodedCertificate)
import Cometa.Error (Error)
import Cometa.Evaluation (RedeemerId)
import Cometa.Governance.Proposal (Proposal)
import Cometa.Governance.Voting (Voter)
import qualified Cometa.Internal.ContextualTransaction as Native
import qualified Cometa.Internal.TransactionIndices as Indices
import Cometa.PolicyId (PolicyId)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Witnesses as Witnesses
import Data.ByteString (ByteString)
import Data.Word (Word64)

-- DEFINITIONS ----------------------------------------------------------------

-- | First spending reference in hash-byte then numeric-index order. Duplicates
-- occupy separate positions.
findInput :: Input -> Tx.Transaction -> Maybe Word64
findInput reference = Indices.findInput reference . fields

-- | First reference input in the same order as 'findInput'.
findReferenceInput :: Input -> Tx.Transaction -> Maybe Word64
findReferenceInput reference = Indices.findReferenceInput reference . fields

-- | First output at the exact address containing at least the minimum lovelace.
-- Output creation order is retained; the minimum spans unsigned 64-bit values.
findOutput :: Address -> Word64 -> Tx.Transaction -> Maybe Word64
findOutput destination minimumLovelace = Indices.findOutput destination minimumLovelace . fields

-- | Policy position in ascending hash-byte order. Imported policies with only
-- zero quantities or an empty asset map still occupy positions.
findMintPolicy :: PolicyId -> Tx.Transaction -> Maybe Word64
findMintPolicy policy = Indices.findMintPolicy policy . bodyBytes

-- | Withdrawal position in ledger reward-account order: test networks before
-- mainnet, then script credentials before key credentials, then hash bytes.
-- All network tags other than 1 belong to the same test-network class.
findWithdrawal :: RewardAddress -> Tx.Transaction -> Maybe Word64
findWithdrawal account = Indices.findWithdrawal account . fields

-- | First certificate with the same native canonical encoding. Certificate
-- list order and duplicates count. Imported representation differences are
-- normalized by the native certificate codecs; no transaction bytes change.
findCertificate :: EncodedCertificate -> Tx.Transaction -> IO (Either Error (Maybe Word64))
findCertificate certificate = Native.findCertificate certificate . Indices.certificateBytes . bodyBytes

-- | Voter position in ledger role order: committee, DRep, stake pool. Within
-- each role script credentials precede key credentials, then hash bytes order
-- each kind. Multiple action votes by one voter occupy a single position.
findVote :: Voter -> Tx.Transaction -> Maybe Word64
findVote voter = Indices.findVote voter . fields

-- | First proposal with the same canonical encoding, including its deposit,
-- return account and anchor. Positions follow proposal insertion order, counting
-- actions without scripts. A proposing redeemer uses this same position.
findProposal :: Proposal -> Tx.Transaction -> Maybe Word64
findProposal proposal = Indices.findProposal proposal . fields

-- | Redeemer rank ordered by purpose then purpose index, independently of its
-- imported witness collection order. This is its position among all redeemers,
-- rather than its position in the body collection authorized by the script.
findRedeemer :: RedeemerId -> Tx.Transaction -> Maybe Word64
findRedeemer identifier = Indices.findRedeemer identifier . Witnesses.redeemers . Witnesses.toWitnesses . Tx.witnesses

fields :: Tx.Transaction -> Fields.Fields
fields = Body.bodyFields . Body.toBody . Tx.body

bodyBytes :: Tx.Transaction -> ByteString
bodyBytes = Body.toCbor . Tx.body
