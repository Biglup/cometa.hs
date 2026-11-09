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

-- | Inspect Cardano domain values using the CIP-116 JSON representation.
-- Large ledger integers become decimal strings and binary fields use explicit
-- text encodings. Object key order is insignificant. Inspection does not change
-- input encodings, validate ledger acceptance, sign or submit transactions.
-- Results are descriptive JSON, not exact-CBOR interchange. Render with
-- 'Data.Aeson.encode'. Expected validation/native failures remain explicit.
--
-- @
-- inspected <- Inspection.output output
-- -- fmap Data.Aeson.encode inspected
-- @
module Cometa.Inspection
  ( transaction,
    subTransaction,
    body,
    subBody,
    value,
    script,
    nativeScript,
    plutusScript,
    credential,
    certificate,
    governanceAction,
    proposal,
    poolParameters,
    protocolUpdate,
    plutusData,
    output,
    witnesses,
    utxo,
    drep,
    actionId,
    anchor,
    votingProcedures,
    metadatum,
    metadata,
    auxiliaryData,
    input,
    datum,
    redeemer,
    exUnits,
    protocolVersion,
    unitInterval,
    relay,
    poolMetadata,
    constitution,
    voter,
    votingProcedure,
    verificationWitness,
    bootstrapWitness,
    costModel,
    costModels,
    exUnitPrices,
    poolVotingThresholds,
    drepVotingThresholds,
    proposedUpdates,
    updateProposal,
    balanceInterval,
    balanceIntervals,
    directDeposits,
    requiredGuards,
    assetName,
    blake2bHash,
    blsKey,
    committeeMembers,
    withdrawals,
    hashes,
    guards,
    subTransactions,
    assets,
    assetEntries,
    policyAssets,
    policyAssetEntries,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as Encoding
import qualified Codec.CBOR.Write as Write
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.AssetName as Name
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Hash
import qualified Cometa.Encoding.Collections as Collections
import Cometa.Error (Error (InvalidValueCbor, NativeContractViolation))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Committee as Committee
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.Inspection as Internal
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Pool.BlsKey as Bls
import qualified Cometa.Pool.Metadata as PoolMetadata
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Pool.Relay as Relay
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.DRepVotingThresholds as DRepThresholds
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as ExUnits
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Cometa.Protocol.PoolVotingThresholds as PoolThresholds
import qualified Cometa.Protocol.ProposedUpdates as Proposed
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import Cometa.Transaction.Inspection (body, subBody, subTransaction, transaction)
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.UnitInterval as Unit
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Data.Aeson (Value (Object), toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word64)
import Foreign.C.Types (CUInt)

-- DEFINITIONS ----------------------------------------------------------------

-- | Inspect a standalone value, including signed native-asset quantities.
-- Ada must be nonnegative and all quantities must fit the native signed
-- 64-bit range. Invalid quantities return the errors from 'Value.encodeCbor'.
value :: Value.Value -> IO (Either Error Value)
value amount = case Value.encodeCbor amount of
  Left failure -> pure (Left failure)
  Right bytes -> Internal.inspect "inspection.value" 4 bytes

-- | Inspect a script with a @native_script@ or @plutus_script@ tag and payload.
script :: Script.Script -> IO (Either Error Value)
script = Internal.inspect "inspection.script" 5 . Script.encodeCbor

-- | Inspect only the native-script payload, including recursive signature,
-- threshold, time and guard conditions. Omits the outer 'script' tag wrapper;
-- this is the CIP-116 schema, distinct from native-script construction JSON.
nativeScript :: Native.NativeScript -> IO (Either Error Value)
nativeScript = scriptPayload . Script.Native

-- | Inspect the language name and compiled bytes of a Plutus script, without
-- the outer 'script' tag wrapper. Does not check program executability.
plutusScript :: Plutus.PlutusScript -> IO (Either Error Value)
plutusScript = scriptPayload . Script.Plutus

scriptPayload :: Script.Script -> IO (Either Error Value)
scriptPayload suppliedScript = do
  result <- script suppliedScript
  pure $ do
    json <- result
    case json of
      Object fields -> maybe failure Right (KeyMap.lookup "value" fields)
      _ -> failure
  where
    failure = Left (NativeContractViolation "inspection.script.payload")

-- | Inspect a role-indexed key or script credential as its tagged hash.
credential :: Credential.Credential purpose -> IO (Either Error Value)
credential = Internal.inspect "inspection.credential" 6 . Credential.encodeCbor

-- | Inspect one staking, pool, committee or DRep certificate. Deposits, refunds
-- and epochs describe the supplied certificate without checking chain state.
certificate :: Certificate.Certificate -> IO (Either Error Value)
certificate = Internal.inspect "inspection.certificate" 7 . Certificate.encodeCbor

-- | Inspect a governance action, including its concrete action tag and fields.
-- Does not establish eligibility or interpret protocol activation rules.
governanceAction :: Action.Action -> IO (Either Error Value)
governanceAction = Internal.inspect "inspection.governanceAction" 19 . Action.encodeCbor

-- | Inspect the deposit, return account, governance action and proposal anchor.
proposal :: Proposal.Proposal -> IO (Either Error Value)
proposal = Internal.inspect "inspection.proposal" 8 . Proposal.encodeCbor

-- | Inspect the complete supplied pool registration parameters, including BLS,
-- relay, owner and metadata fields when present.
poolParameters :: Pool.PoolParameters -> IO (Either Error Value)
poolParameters = Internal.inspect "inspection.poolParameters" 9 . Pool.encodeCbor

-- | Inspect supplied sparse protocol changes. Absent fields stay absent;
-- no current protocol snapshot or ledger-state query is performed.
protocolUpdate :: Update.Update -> IO (Either Error Value)
protocolUpdate = Internal.inspect "inspection.protocolUpdate" 10 . Update.encodeCbor

-- | Inspect exact encoded script data. Arbitrary integers use decimal strings;
-- map entry order and duplicate keys remain represented in the JSON arrays.
plutusData :: Data.EncodedPlutusData -> IO (Either Error Value)
plutusData = Internal.inspect "inspection.plutusData" 11 . Data.toCbor

-- | Inspect one output's address, value, datum and optional reference script.
output :: Output.Output -> IO (Either Error Value)
output = Internal.inspect "inspection.output" 12 . Output.encodeCbor

-- | Inspect exact witness fields, including key witnesses, scripts, data and
-- redeemers. Does not verify signatures, budgets or script execution.
witnesses :: Witnesses.EncodedWitnesses -> IO (Either Error Value)
witnesses = Internal.inspect "inspection.witnesses" 13 . Witnesses.toCbor

-- | Inspect an input reference paired with its resolved output. Does not check
-- whether the output exists or is currently unspent on a network.
utxo :: Utxo.Utxo -> IO (Either Error Value)
utxo = Internal.inspect "inspection.utxo" 14 . Utxo.encodeCbor

-- | Inspect a credential DRep or either predefined delegation target.
drep :: DRep.DRep -> IO (Either Error Value)
drep = Internal.inspect "inspection.drep" 15 . DRep.encodeCbor

-- | Inspect a transaction identifier and governance-action index.
actionId :: ActionId.ActionId -> IO (Either Error Value)
actionId = Internal.inspect "inspection.actionId" 16 . ActionId.encodeCbor

-- | Inspect the metadata URL and content hash without fetching the URL.
anchor :: Anchor.Anchor -> IO (Either Error Value)
anchor = Internal.inspect "inspection.anchor" 17 . Anchor.encodeCbor

-- | Inspect voter/action choices and optional explanation anchors. Collection
-- order follows the supplied validated representation; no vote is submitted.
votingProcedures :: Voting.VotingProcedures -> IO (Either Error Value)
votingProcedures = Internal.inspect "inspection.votingProcedures" 18 . Voting.encodeCbor

-- | Inspect one validated metadata value using the tagged CIP-116 schema.
-- Nested map order and duplicate keys remain represented in the result. This
-- differs from the detailed and plain JSON codecs in "Cometa.Metadata".
metadatum :: Metadata.Metadatum -> IO (Either Error Value)
metadatum = Internal.inspect "inspection.metadatum" 20 . Metadata.encodeMetadatumCbor

-- | Inspect transaction metadata as an ordered array of label/value entries.
-- Labels use decimal strings; each value uses the tagged CIP-116 schema.
metadata :: Metadata.Metadata -> IO (Either Error Value)
metadata = Internal.inspect "inspection.metadata" 21 . Metadata.encodeCbor

-- | Inspect exact auxiliary data, including metadata and native/Plutus scripts.
-- Retains source encodings and auxiliary-data hashes without recalculation.
auxiliaryData :: Auxiliary.EncodedAuxiliaryData -> IO (Either Error Value)
auxiliaryData = Internal.inspect "inspection.auxiliaryData" 22 . Auxiliary.toCbor

-- | Inspect the transaction identifier and output index of an input reference.
-- Does not resolve the referenced output or establish its availability.
input :: Input.Input -> IO (Either Error Value)
input = Internal.inspect "inspection.input" 23 . Input.encodeCbor

-- | Inspect a datum hash or inline datum. 'Datum.NoDatum' returns 'Nothing'
-- without allocating a native datum;
-- the other alternatives return the tagged native CIP-116 datum object.
-- Inline data retains its arbitrary integers, map order and duplicate keys.
datum :: Datum.Datum -> IO (Either Error (Maybe Value))
datum Datum.NoDatum = pure (Right Nothing)
datum (Datum.DatumHash hash) = inspectDatum (Encoding.encodeListLen 2 <> Encoding.encodeWord 0 <> Encoding.encodeBytes (Datum.hashBytes hash))
datum (Datum.InlineDatum payload) = inspectDatum (Encoding.encodeListLen 2 <> Encoding.encodeWord 1 <> Encoding.encodeTag 24 <> Encoding.encodeBytes (Data.toCbor payload))

inspectDatum :: Encoding.Encoding -> IO (Either Error (Maybe Value))
inspectDatum = fmap (fmap Just) . Internal.inspect "inspection.datum" 24 . Write.toStrictByteString

-- | Inspect a redeemer's purpose, index, script data and declared execution
-- units. Does not execute the script or check its budget against a transaction.
redeemer :: Redeemer.Redeemer -> IO (Either Error Value)
redeemer = Internal.inspect "inspection.redeemer" 25 . Redeemer.encodeCbor

-- | Inspect declared memory and CPU steps as decimal strings; no evaluation is performed.
exUnits :: ExUnits.ExUnits -> IO (Either Error Value)
exUnits = Internal.inspect "inspection.exUnits" 26 . ExUnits.encodeCbor

-- | Inspect protocol major and minor versions as JSON numbers.
protocolVersion :: Version.ProtocolVersion -> IO (Either Error Value)
protocolVersion = Internal.inspect "inspection.protocolVersion" 27 . Version.encodeCbor

-- | Inspect the exact rational numerator and denominator as decimal strings.
unitInterval :: Unit.UnitInterval -> IO (Either Error Value)
unitInterval = Internal.inspect "inspection.unitInterval" 28 . Unit.encodeCbor

-- | Inspect a pool relay, preserving absent ports and IP addresses as null.
relay :: Relay.Relay -> IO (Either Error Value)
relay = Internal.inspect "inspection.relay" 29 . Relay.encodeCbor

-- | Inspect a pool metadata URL and hash without fetching the URL.
poolMetadata :: PoolMetadata.Metadata -> IO (Either Error Value)
poolMetadata = Internal.inspect "inspection.poolMetadata" 30 . PoolMetadata.encodeCbor

-- | Inspect a constitution anchor and optional guardrails hash; absence omits the hash.
constitution :: Constitution.Constitution -> IO (Either Error Value)
constitution = Internal.inspect "inspection.constitution" 31 . Constitution.encodeCbor

-- | Inspect a committee, DRep or stake-pool voting identity with its role tag.
voter :: Voting.Voter -> IO (Either Error Value)
voter = Internal.inspect "inspection.voter" 32 . Voting.encodeVoter

-- | Inspect a vote choice and optional explanation anchor; absence omits the anchor.
votingProcedure :: Voting.VotingProcedure -> IO (Either Error Value)
votingProcedure = Internal.inspect "inspection.votingProcedure" 33 . Voting.encodeProcedure

-- | Inspect a verification key and signature without verifying the signature.
verificationWitness :: Witness.VerificationWitness -> IO (Either Error Value)
verificationWitness = Internal.inspect "inspection.verificationWitness" 34 . Witness.encodeCbor

-- | Inspect a Byron witness key, signature, chain code and attributes as hexadecimal.
bootstrapWitness :: Witness.BootstrapWitness -> IO (Either Error Value)
bootstrapWitness = Internal.inspect "inspection.bootstrapWitness" 35 . Witness.encodeBootstrapCbor

-- | Inspect ordered signed costs as decimal strings. The language belongs to the
-- enclosing map and is absent from this array.
costModel :: Models.CostModel -> IO (Either Error Value)
costModel = Internal.inspect "inspection.costModel" 36 . costModelBytes

-- | Inspect known Plutus V1–V4 cost arrays. Unknown language identifiers are
-- omitted by this schema; input values and encodings remain unchanged.
costModels :: Models.CostModels -> IO (Either Error Value)
costModels = Internal.inspect "inspection.costModels" 37 . Models.encodeCbor

-- | Inspect exact lovelace prices for memory and steps. Original
-- numerator/denominator components are retained, including prices greater than
-- one.
exUnitPrices :: Prices.ExUnitPrices -> IO (Either Error Value)
exUnitPrices = Internal.inspect "inspection.exUnitPrices" 38 . Prices.encodeCbor

-- | Inspect all five stake-pool approval thresholds as exact rational components.
poolVotingThresholds :: PoolThresholds.PoolVotingThresholds -> IO (Either Error Value)
poolVotingThresholds = Internal.inspect "inspection.poolVotingThresholds" 39 . PoolThresholds.encodeCbor

-- | Inspect all ten DRep approval thresholds as exact rational components.
drepVotingThresholds :: DRepThresholds.DRepVotingThresholds -> IO (Either Error Value)
drepVotingThresholds = Internal.inspect "inspection.drepVotingThresholds" 40 . DRepThresholds.encodeCbor

-- | Inspect legacy genesis-authorized sparse changes as an object keyed by
-- hexadecimal genesis hashes. No authorization or era eligibility is
-- established.
proposedUpdates :: Proposed.ProposedUpdates -> IO (Either Error Value)
proposedUpdates = Internal.inspect "inspection.proposedUpdates" 41 . Proposed.encodeCbor

-- | Inspect a legacy update proposal and activation epoch. Epoch is a JSON
-- number, unlike decimal-string ledger quantities.
updateProposal :: Proposed.UpdateProposal -> IO (Either Error Value)
updateProposal = Internal.inspect "inspection.updateProposal" 42 . Proposed.encodeProposal

-- | Inspect an exact lovelace balance or inclusive-lower/exclusive-upper range.
-- Absent bounds are null; contradictory bounds are described without ledger-
-- state validation. A range with both bounds absent returns a native invalid-
-- argument error.
balanceInterval :: Fields.BalanceInterval -> IO (Either Error Value)
balanceInterval = Internal.inspect "inspection.balanceInterval" 43 . balanceIntervalBytes

-- | Inspect account balance requirements as ordered key/value entries. Keys are
-- reward addresses; bounds use the balance-interval schema.
balanceIntervals :: Fields.Entries Reward.RewardAddress Fields.BalanceInterval -> IO (Either Error Value)
balanceIntervals = Internal.inspect "inspection.balanceIntervals" 44 . balanceIntervalsBytes

-- | Inspect reward-account deposits as ordered key/value entries, preserving
-- present zero amounts as decimal strings.
directDeposits :: Fields.Entries Reward.RewardAddress Word64 -> IO (Either Error Value)
directDeposits = Internal.inspect "inspection.directDeposits" 45 . directDepositsBytes

-- | Inspect required guard credentials and optional exact script data as ordered
-- key/value entries. Absent data is null; script-data map order and duplicate
-- keys are retained.
requiredGuards :: Fields.Entries (Credential.Credential Credential.Guard) (Maybe Data.EncodedPlutusData) -> IO (Either Error Value)
requiredGuards = Internal.inspect "inspection.requiredGuards" 46 . requiredGuardsBytes

costModelBytes :: Models.CostModel -> ByteString
costModelBytes model = Write.toStrictByteString (Encoding.encodeListLen 2 <> Encoding.encodeWord8 (Models.languageId model)) <> Models.encodeCostModelCbor model

balanceIntervalEncoding :: Fields.BalanceInterval -> Encoding.Encoding
balanceIntervalEncoding interval = case interval of
  Fields.ExactBalance amount -> Encoding.encodeWord64 amount
  Fields.BalanceRange lower upper -> Encoding.encodeListLen 2 <> maybe Encoding.encodeNull Encoding.encodeWord64 lower <> maybe Encoding.encodeNull Encoding.encodeWord64 upper

balanceIntervalBytes :: Fields.BalanceInterval -> ByteString
balanceIntervalBytes = Write.toStrictByteString . balanceIntervalEncoding

associationBytes :: (key -> Encoding.Encoding) -> (value -> Encoding.Encoding) -> Fields.Entries key value -> ByteString
associationBytes encodeKey encodeValue entries = Write.toStrictByteString (Encoding.encodeMapLen (fromIntegral (length pairs)) <> foldMap (\(key, payload) -> encodeKey key <> encodeValue payload) pairs)
  where
    pairs = Fields.entries entries

balanceIntervalsBytes :: Fields.Entries Reward.RewardAddress Fields.BalanceInterval -> ByteString
balanceIntervalsBytes = associationBytes (Encoding.encodeBytes . Reward.toBytes) balanceIntervalEncoding

directDepositsBytes :: Fields.Entries Reward.RewardAddress Word64 -> ByteString
directDepositsBytes = associationBytes (Encoding.encodeBytes . Reward.toBytes) Encoding.encodeWord64

requiredGuardsBytes :: Fields.Entries (Credential.Credential Credential.Guard) (Maybe Data.EncodedPlutusData) -> ByteString
requiredGuardsBytes entries = Write.toStrictByteString (Encoding.encodeMapLen (fromIntegral (length pairs))) <> foldMap encodePair pairs
  where
    pairs = Fields.entries entries
    encodePair (key, payload) = Credential.encodeCbor key <> maybe (Write.toStrictByteString Encoding.encodeNull) Data.toCbor payload

-- | Inspect an asset name as lowercase hexadecimal, including the empty name.
-- Text decoding is not attempted.
assetName :: Name.AssetName -> IO (Either Error Value)
assetName = Internal.inspect "inspection.assetName" 47 . Name.encodeCbor

-- | Inspect a validated nonempty digest as lowercase hexadecimal. No hashing or
-- role inference is performed.
blake2bHash :: Hash.Blake2bHash -> IO (Either Error Value)
blake2bHash = Internal.inspect "inspection.blake2bHash" 48 . Hash.encodeCbor

-- | Inspect a pool BLS public key (96 bytes) and possession proof (48 bytes) as
-- hexadecimal. No group-membership or proof verification is performed.
blsKey :: Bls.BlsKey -> IO (Either Error Value)
blsKey = Internal.inspect "inspection.blsKey" 49 . Bls.encodeCbor

-- | Inspect cold committee credentials and expiry epochs as ordered key/value
-- entries. Credential kind and hash determine order; epochs are decimal
-- strings.
committeeMembers :: Committee.Members -> IO (Either Error Value)
committeeMembers = Internal.inspect "inspection.committeeMembers" 50 . Committee.encodeMembers

-- | Inspect reward accounts and withdrawn lovelace as ordered key/value entries.
-- Empty input, zero and duplicate accounts are retained. Accounts sort stably
-- by encoded address bytes, distinct from ledger redeemer-index ordering.
withdrawals :: [(Reward.RewardAddress, Word64)] -> IO (Either Error Value)
withdrawals = Internal.inspect "inspection.withdrawals" 51 . Collections.encodeWithdrawalsCbor

-- | Inspect digests as a JSON array, sorted stably by byte length then bytes.
-- Duplicate digests remain; empty input produces an empty array.
hashes :: [Hash.Blake2bHash] -> IO (Either Error Value)
hashes = Internal.inspect "inspection.hashes" 52 . Collections.encodeHashesCbor

-- | Inspect guards in supplied order. Empty input returns an empty array.
-- Key and script credentials remain tagged;
-- repeated credentials return a native duplicate-key error.
guards :: [Credential.Credential Credential.Guard] -> IO (Either Error Value)
guards [] = pure (Right (toJSON ([] :: [Value])))
guards credentials = Internal.inspect "inspection.guards" 53 (credentialListBytes credentials)

-- | Inspect subtransactions in supplied order. Empty input returns an empty
-- array. Repeated body identifiers return
-- a native duplicate-key error, even if witnesses or outer framing differ.
-- Signed body encodings are unchanged.
subTransactions :: [Sub.SubTransaction] -> IO (Either Error Value)
subTransactions [] = pure (Right (toJSON ([] :: [Value])))
subTransactions transactions = Internal.inspect "inspection.subTransactions" 54 (subTransactionsBytes transactions)

-- | Inspect policy/name associations as a JSON object keyed by hexadecimal
-- policies and names. Empty policy groups and zero quantities remain present.
-- Quantities must fit signed 64 bits ('Cometa.Error.InvalidValueQuantity').
-- Repeated policies use their last supplied group. Repeated names in a retained
-- group return 'InvalidValueCbor': object keys cannot retain repeated entries.
-- Ordering of object properties is insignificant.
assets :: [(Policy.PolicyId, [(Name.AssetName, Integer)])] -> IO (Either Error Value)
assets = inspectAssetAssociations "inspection.assets" 55

-- | Inspect policy groups as ordered @{script_hash, assets}@ entries. The inner
-- @assets@ value is a name-keyed object, not an asset-entry array. Groups sort
-- stably by policy bytes; empty groups and zero remain. Repeated policies use
-- the last supplied group, matching native map decoding.
-- Duplicate names return 'InvalidValueCbor'; signed overflow returns
-- 'Cometa.Error.InvalidValueQuantity'. Use 'policyAssetEntries' for repeated names.
assetEntries :: [(Policy.PolicyId, [(Name.AssetName, Integer)])] -> IO (Either Error Value)
assetEntries = inspectAssetAssociations "inspection.assetEntries" 56

-- | Inspect one policy's name/quantity associations as a hexadecimal-name-keyed
-- object. Empty input and explicit zero are retained. Repeated names return
-- 'InvalidValueCbor'; quantities outside signed 64 bits return
-- 'Cometa.Error.InvalidValueQuantity'. No policy identity is required.
policyAssets :: [(Name.AssetName, Integer)] -> IO (Either Error Value)
policyAssets pairs = case encoded of
  Left failure -> pure (Left failure)
  Right bytes -> Internal.inspect "inspection.policyAssets" 57 bytes
  where
    encoded = do
      bytes <- Collections.encodeAssetNamesCbor pairs
      uniqueObjectKeys "Repeated asset names cannot be represented as JSON object keys" (map fst pairs)
      pure bytes

-- | Inspect one policy's assets as ordered @{asset_name, amount}@ entries.
-- Names sort stably by byte length then bytes; repeated names keep their relative
-- order. Empty input and explicit zeros remain. Quantities outside signed 64 bits
-- return 'Cometa.Error.InvalidValueQuantity'. No policy identity is required.
policyAssetEntries :: [(Name.AssetName, Integer)] -> IO (Either Error Value)
policyAssetEntries pairs = case Collections.encodeAssetNamesCbor pairs of
  Left failure -> pure (Left failure)
  Right bytes -> Internal.inspect "inspection.policyAssetEntries" 58 bytes

inspectAssetAssociations :: Text -> CUInt -> [(Policy.PolicyId, [(Name.AssetName, Integer)])] -> IO (Either Error Value)
inspectAssetAssociations operation kind pairs = case encoded of
  Left failure -> pure (Left failure)
  Right bytes -> Internal.inspect operation kind bytes
  where
    encoded = do
      groups <- traverse encodeGroup (sortOn (Policy.toBytes . fst) pairs)
      mapM_ (uniqueObjectKeys "Repeated asset names cannot be represented as JSON object keys" . map fst) (Map.elems (Map.fromList pairs))
      pure (Write.toStrictByteString (Encoding.encodeMapLen (fromIntegral (length groups))) <> mconcat groups)
    encodeGroup (policy, quantities) = do
      bytes <- Collections.encodeAssetNamesCbor quantities
      pure (Write.toStrictByteString (Encoding.encodeBytes (Policy.toBytes policy)) <> bytes)

uniqueObjectKeys :: (Ord key) => Text -> [key] -> Either Error ()
uniqueObjectKeys message keys = unless (Set.size (Set.fromList keys) == length keys) (Left (InvalidValueCbor message))

credentialListBytes :: [Credential.Credential purpose] -> ByteString
credentialListBytes credentials = Write.toStrictByteString (Encoding.encodeTag 258 <> Encoding.encodeListLen (fromIntegral (length credentials))) <> foldMap Credential.encodeCbor credentials

subTransactionsBytes :: [Sub.SubTransaction] -> ByteString
subTransactionsBytes transactions = Write.toStrictByteString (Encoding.encodeTag 258 <> Encoding.encodeListLen (fromIntegral (length transactions))) <> foldMap Sub.encodeCbor transactions
