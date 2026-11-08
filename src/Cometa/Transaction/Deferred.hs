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

-- | Pure queries of the current builder draft for deferred redeemers. Compose
-- required indices, inspect selected inputs, then supply an explicit script-data
-- encoder to 'redeemer'. Queries run again whenever the builder invokes the
-- callback; positions are specific to that draft, not the final signed body.
--
-- @
-- import qualified Cometa.PlutusData as Data
-- import qualified Cometa.Transaction.Deferred as Deferred
--
-- spendingRedeemer reference =
--   Deferred.redeemer (Data.Integer . toInteger) (Deferred.inputIndex reference)
-- @
module Cometa.Transaction.Deferred
  ( Query,
    draft,
    selectedInputs,
    fromEither,
    run,
    inputIndex,
    referenceInputIndex,
    mintPolicyIndex,
    withdrawalIndex,
    voteIndex,
    proposalIndex,
    redeemerIndex,
    outputIndex,
    outputIndexWhere,
    redeemer,
    encodedRedeemer,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Address.Reward (RewardAddress)
import Cometa.Error (Error (InvalidBuildingRequest))
import Cometa.Evaluation (RedeemerId)
import Cometa.Governance.Proposal (Proposal)
import Cometa.Governance.Voting (Voter)
import qualified Cometa.PlutusData as Data
import Cometa.PolicyId (PolicyId)
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Indices as Indices
import Cometa.Transaction.Input (Input)
import Cometa.Transaction.Output (Output)
import Cometa.Transaction.Plan (DeferredRedeemer)
import Cometa.Transaction.Utxo (Utxo)
import Data.Text (Text)
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | A read-only draft query with explicit expected failure. 'Functor',
-- 'Applicative' and 'Monad' share the same immutable draft and selected-input
-- snapshot throughout a run and stop at the first 'Left'. No native or network
-- effects occur. The constructor is hidden; use the queries and 'fromEither'.
newtype Query a = Query (Transaction -> [Utxo] -> Either Error a)

instance Functor Query where
  fmap f (Query query) = Query (\transaction inputs -> fmap f (query transaction inputs))

instance Applicative Query where
  pure value = Query (\_ _ -> Right value)
  Query function <*> Query argument = Query $ \transaction inputs ->
    function transaction inputs <*> argument transaction inputs

instance Monad Query where
  Query query >>= next = Query $ \transaction inputs -> do
    value <- query transaction inputs
    run (next value) transaction inputs

-- DEFINITIONS ----------------------------------------------------------------

-- | The current callback draft. Inspect it with the ordinary pure transaction
-- observers. Subsequent balancing may change its body and indices.
draft :: Query Transaction
draft = Query (\transaction _ -> Right transaction)

-- | The exact selected-input list supplied to this callback, retaining order.
-- This is not a network query and need not include reference inputs. 'run' does
-- not validate or reorder an independently supplied snapshot.
selectedInputs :: Query [Utxo]
selectedInputs = Query (\_ inputs -> Right inputs)

-- | Lift existing pure validation. A 'Left' stops subsequent query steps.
fromEither :: Either Error a -> Query a
fromEither result = Query (\_ _ -> result)

-- | Evaluate against one draft and selected-input snapshot. Useful for testing
-- a query before installing it in a plan. Inputs remain unchanged.
run :: Query a -> Transaction -> [Utxo] -> Either Error a
run (Query query) = query

-- | Required spending-input position in hash-byte then numeric-index order.
-- Duplicates use their first position. Absence returns 'InvalidBuildingRequest'.
inputIndex :: Input -> Query Word64
inputIndex reference = required "Deferred spending input is missing" (Indices.findInput reference)

-- | Required reference-input position in the same order as 'inputIndex'.
-- Absence returns 'InvalidBuildingRequest'.
referenceInputIndex :: Input -> Query Word64
referenceInputIndex reference = required "Deferred reference input is missing" (Indices.findReferenceInput reference)

-- | Required mint-policy position in ascending policy-hash order. Empty and
-- zero-quantity imported policies count. Absence returns 'InvalidBuildingRequest'.
mintPolicyIndex :: PolicyId -> Query Word64
mintPolicyIndex policy = required "Deferred mint policy is missing" (Indices.findMintPolicy policy)

-- | Required withdrawal position in ledger reward-account order, as documented
-- by 'Indices.findWithdrawal'. Absence returns 'InvalidBuildingRequest'.
withdrawalIndex :: RewardAddress -> Query Word64
withdrawalIndex account = required "Deferred withdrawal is missing" (Indices.findWithdrawal account)

-- | Required voter position in ledger role and credential order, independent
-- of the number of action votes. Absence returns 'InvalidBuildingRequest'.
voteIndex :: Voter -> Query Word64
voteIndex voter = required "Deferred voter is missing" (Indices.findVote voter)

-- | Required proposal position in insertion order, comparing canonical
-- encodings and using the first duplicate. Absence returns 'InvalidBuildingRequest'.
proposalIndex :: Proposal -> Query Word64
proposalIndex proposal = required "Deferred proposal is missing" (Indices.findProposal proposal)

-- | Required rank among redeemers ordered by purpose and purpose index. This
-- is not the authorized body-item index. Absence returns 'InvalidBuildingRequest'.
redeemerIndex :: RedeemerId -> Query Word64
redeemerIndex identifier = required "Deferred redeemer is missing" (Indices.findRedeemer identifier)

required :: Text -> (Transaction -> Maybe Word64) -> Query Word64
required message lookupIndex = do
  transaction <- draft
  fromEither (maybe (Left (InvalidBuildingRequest message)) Right (lookupIndex transaction))

-- | Unique output with equal semantic fields, including exact inline datum
-- bytes. Creation order determines the index. Missing or multiple equal outputs
-- return 'InvalidBuildingRequest'; no first-match choice is made.
outputIndex :: Output -> Query Word64
outputIndex output = outputIndexWhere (== output)

-- | Unique output satisfying a pure predicate, in creation order. No match or
-- multiple matches return distinct 'InvalidBuildingRequest' diagnostics.
outputIndexWhere :: (Output -> Bool) -> Query Word64
outputIndexWhere matches = do
  transaction <- draft
  let outputs = Fields.fieldOutputs (Body.bodyFields (Body.toBody (Tx.body transaction)))
      positions = [index | (index, output) <- zip [0 ..] outputs, matches output]
  fromEither $ case positions of
    [] -> Left (InvalidBuildingRequest "Deferred output is missing")
    [index] -> Right index
    _ -> Left (InvalidBuildingRequest "Deferred output is ambiguous")

-- | Turn a query into the existing plan callback using an explicit application
-- data encoder. Encoding uses 'Data.fromData'; the query's first failure is
-- propagated unchanged. Repeated callbacks rerun the query against each draft.
redeemer :: (a -> Data.PlutusData) -> Query a -> DeferredRedeemer
redeemer encode query = encodedRedeemer (Data.fromData . encode <$> query)

-- | Turn exact validated script data into the existing plan callback without
-- re-encoding its CBOR. Compatible with top-level and subtransaction plan
-- callbacks; both receive the builder's 'Transaction' draft. Pure index queries
-- inspect the supplied draft's top-level body and do not descend into nested
-- subtransactions. Use a raw callback for other contextual policies.
encodedRedeemer :: Query Data.EncodedPlutusData -> DeferredRedeemer
encodedRedeemer = run
