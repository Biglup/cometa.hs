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
{-# OPTIONS_HADDOCK hide #-}

-- | Sub-transaction plans share validated instructions and callback indexing
-- with ordinary plans while exposing only the sub-transaction schema.
module Cometa.Internal.SubTransactionPlan
  ( Plan,
    DeferredRedeemer,
    payTo,
    spend,
    spendWith,
    spendWithDeferredRedeemer,
    referenceInput,
    attachScript,
    mint,
    mintWithRedeemer,
    mintWithDeferredRedeemer,
    metadata,
    attachDatum,
    certificate,
    certificateWithRedeemer,
    certificateWithDeferredRedeemer,
    withdraw,
    withdrawWithRedeemer,
    withdrawWithDeferredRedeemer,
    requireSigner,
    validFrom,
    validUntil,
    requireTopLevelGuard,
    requireGuard,
    guardWithRedeemer,
    directDeposit,
    accountBalance,
    donate,
    propose,
    vote,
    voteWithRedeemer,
    voteWithDeferredRedeemer,
    resolvedInputs,
    toPlan,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Address.Reward (RewardAddress)
import Cometa.AssetId (AssetId)
import Cometa.AssetName (AssetName)
import Cometa.Certificate (Certificate)
import Cometa.Credential (Credential, Guard, KeyHash, Payment, ScriptHash)
import Cometa.Error (Error)
import Cometa.Governance.Action (Action)
import Cometa.Governance.ActionId (ActionId)
import Cometa.Governance.Anchor (Anchor)
import Cometa.Governance.Voting (Voter, VotingProcedure)
import qualified Cometa.Internal.TransactionPlan as Top
import Cometa.Metadata (Metadatum)
import Cometa.PlutusData (EncodedPlutusData)
import Cometa.PolicyId (PolicyId)
import Cometa.Script (Script)
import Cometa.Transaction (Transaction)
import Cometa.Transaction.Fields (BalanceInterval)
import Cometa.Transaction.Output (Output)
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Ordered intent instructions. Composition combines mint quantities and
-- validity requirements, preserving outputs and certificate order. Conflicting
-- arguments or snapshots fail when building. Plans contain functions, so their
-- monoid laws concern behavior rather than structural equality.
newtype Plan = Plan Top.Plan

instance Semigroup Plan where
  Plan left <> Plan right = Plan (left <> right)

instance Monoid Plan where
  mempty = Plan mempty

-- | Compute an argument once from the local draft: its fee is zero, inputs and
-- redeemer indices are local to the sub-transaction, and resolved spending
-- inputs are in canonical order. Reference inputs are available in the draft
-- body but absent from the supplied spending snapshot. Return an error to abort.
-- The callback must be pure and deterministic. Snapshots are ordinary owned
-- values; no pointer or resource scope escapes the build.
type DeferredRedeemer = Transaction -> [Utxo] -> Either Error EncodedPlutusData

-- DEFINITIONS ----------------------------------------------------------------

-- | Append an output in creation order. Building preserves its exact value.
payTo :: Output -> Plan
payTo a = Plan (Top.payTo a)

-- | Spend exactly this resolved key-controlled output.
spend :: Utxo -> Plan
spend a = Plan (Top.spend a)

-- | Spend a script output with optional argument and datum witness.
spendWith :: Utxo -> Maybe EncodedPlutusData -> Maybe EncodedPlutusData -> Plan
spendWith a b c = Plan (Top.spendWith a b c)

-- | Spend a script output with a local deferred argument and optional datum witness. Register each input once.
spendWithDeferredRedeemer :: Utxo -> DeferredRedeemer -> Maybe EncodedPlutusData -> Plan
spendWithDeferredRedeemer a b c = Plan (Top.spendWithDeferredRedeemer a b c)

-- | Make a resolved reference output available without spending it.
referenceInput :: Utxo -> Plan
referenceInput a = Plan (Top.referenceInput a)

-- | Attach a native or compiled Plutus script. Executed sub-level scripts require V4.
attachScript :: Script -> Plan
attachScript a = Plan (Top.attachScript a)

-- | Mint or burn a native asset. Ada and combined quantity overflow fail at build.
mint :: AssetId -> Int64 -> Plan
mint a b = Plan (Top.mint a b)

-- | Mint or burn a Plutus-policy asset with an immediate argument.
mintWithRedeemer :: AssetId -> Int64 -> EncodedPlutusData -> Plan
mintWithRedeemer a b c = Plan (Top.mintWithRedeemer a b c)

-- | Mint or burn a group of names under one policy with one local deferred argument. Repeated names combine and zero totals disappear. Register each policy once.
mintWithDeferredRedeemer :: PolicyId -> [(AssetName, Int64)] -> DeferredRedeemer -> Plan
mintWithDeferredRedeemer a b c = Plan (Top.mintWithDeferredRedeemer a b c)

-- | Attach a metadata label; conflicting values fail at build.
metadata :: Word64 -> Metadatum -> Plan
metadata a b = Plan (Top.metadata a b)

-- | Attach an exact datum witness.
attachDatum :: EncodedPlutusData -> Plan
attachDatum a = Plan (Top.attachDatum a)

-- | Append a typed certificate without a script argument.
certificate :: Certificate -> Plan
certificate a = Plan (Top.certificate a)

-- | Append a typed certificate authorized by an immediate argument.
certificateWithRedeemer :: Certificate -> EncodedPlutusData -> Plan
certificateWithRedeemer a b = Plan (Top.certificateWithRedeemer a b)

-- | Append a typed certificate authorized by a local deferred argument.
certificateWithDeferredRedeemer :: Certificate -> DeferredRedeemer -> Plan
certificateWithDeferredRedeemer a b = Plan (Top.certificateWithDeferredRedeemer a b)

-- | Withdraw rewards from a key-controlled account. Amounts must fit signed 64-bit.
withdraw :: RewardAddress -> Word64 -> Plan
withdraw a b = Plan (Top.withdraw a b)

-- | Withdraw rewards with an immediate Plutus argument.
withdrawWithRedeemer :: RewardAddress -> Word64 -> EncodedPlutusData -> Plan
withdrawWithRedeemer a b c = Plan (Top.withdrawWithRedeemer a b c)

-- | Withdraw rewards with a local deferred argument. Register each account once.
withdrawWithDeferredRedeemer :: RewardAddress -> Word64 -> DeferredRedeemer -> Plan
withdrawWithDeferredRedeemer a b c = Plan (Top.withdrawWithDeferredRedeemer a b c)

-- | Require a payment key hash as a local guard.
requireSigner :: KeyHash Payment -> Plan
requireSigner a = Plan (Top.requireSigner a)

-- | Inclusive lower validity slot; composition takes the greatest lower bound.
validFrom :: Word64 -> Plan
validFrom a = Plan (Top.validFrom a)

-- | Exclusive upper validity slot; composition takes the least upper bound.
validUntil :: Word64 -> Plan
validUntil a = Plan (Top.validUntil a)

-- | Unique spending and reference snapshots in ascending input-reference order.
-- Conflicting original snapshots are rejected when building.
-- Supply this result alongside a successfully built intent when attaching it
-- to an outer plan.
resolvedInputs :: Plan -> [Utxo]
resolvedInputs (Plan plan) = Map.elems (Map.fromList [(Utxo.input input, input) | input <- Top.resolvedInputs plan])

-- | Internal reuse of common validation, serialization and rooted callbacks.
toPlan :: Plan -> Top.Plan
toPlan (Plan plan) = plan

-- | Require a key or native-script guard. Use guardWithRedeemer for Plutus guards.
requireGuard :: Credential Guard -> Plan
requireGuard credential = Plan (Top.requireGuard credential)

-- | Require a local Plutus guard with its immediate argument.
guardWithRedeemer :: ScriptHash -> EncodedPlutusData -> Plan
guardWithRedeemer hash argument = Plan (Top.guardWithRedeemer hash argument)

-- | Deposit lovelace directly into a reward account. Repeated amounts combine.
directDeposit :: RewardAddress -> Word64 -> Plan
directDeposit account amount = Plan (Top.directDeposit account amount)

-- | Require a reward-account balance interval for this intent.
accountBalance :: RewardAddress -> BalanceInterval -> Plan
accountBalance account interval = Plan (Top.accountBalance account interval)

-- | Donate lovelace to the treasury; repeated donations combine.
donate :: Word64 -> Plan
donate amount = Plan (Top.donate amount)

-- | Append a governance proposal, using the configured governance deposit.
-- Parameter changes and treasury withdrawals require a Plutus V4 guardrails
-- policy hash and its supplied script. They execute with the built-in proposing
-- argument @Constr 0 []@.
propose :: RewardAddress -> Action -> Anchor -> Plan
propose account action anchor = Plan (Top.propose account action anchor)

-- | Cast a key-authorized governance vote.
vote :: Voter -> ActionId -> VotingProcedure -> Plan
vote voter action procedure = Plan (Top.vote voter action procedure)

-- | Cast several votes under one voter with one immediate argument.
voteWithRedeemer :: Voter -> [(ActionId, VotingProcedure)] -> EncodedPlutusData -> Plan
voteWithRedeemer voter votes argument = Plan (Top.voteWithRedeemer voter votes argument)

-- | Cast several votes under one voter with one local deferred argument. Register each voter once; empty groups do not invoke the callback.
voteWithDeferredRedeemer :: Voter -> [(ActionId, VotingProcedure)] -> DeferredRedeemer -> Plan
voteWithDeferredRedeemer voter votes callback = Plan (Top.voteWithDeferredRedeemer voter votes callback)

-- | Require an outer guard and optional datum for this intent. This records a
-- requirement; the enclosing transaction must satisfy it when assembled.
requireTopLevelGuard :: Credential Guard -> Maybe EncodedPlutusData -> Plan
requireTopLevelGuard credential datum = Plan (Top.requireTopLevelGuard credential datum)
