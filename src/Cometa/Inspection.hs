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
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as Encoding
import qualified Codec.CBOR.Write as Write
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (NativeContractViolation))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.Inspection as Internal
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as Data
import qualified Cometa.Pool.Metadata as PoolMetadata
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Pool.Relay as Relay
import qualified Cometa.Protocol.ExUnits as ExUnits
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import Cometa.Transaction.Inspection (body, subBody, subTransaction, transaction)
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.UnitInterval as Unit
import qualified Cometa.Value as Value
import Data.Aeson (Value (Object))
import qualified Data.Aeson.KeyMap as KeyMap

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
