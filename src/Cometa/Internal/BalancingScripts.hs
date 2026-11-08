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
{-# OPTIONS_HADDOCK hide #-}

-- | Select the language views for the outer body's actual script purposes.
-- Mirrors the pinned native get_needed_scripts/get_plutus_languages_used domain
-- traversal, but fails explicitly when a required script or cost model is absent.
-- Script hashing remains in IO; all supplied values and encodings stay unchanged.
module Cometa.Internal.BalancingScripts (usedCostModels) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (InvalidBuildingRequest))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.Parameters (Parameters)
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.ByteString (ByteString)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Word (Word8)

-- DEFINITIONS ----------------------------------------------------------------

-- | Select only languages used by required outer scripts. Nested scripts may
-- provide a needed outer script, but nested purposes do not add outer language
-- views. Relevant reference scripts come only from spending/reference inputs of
-- the outer body and nested bodies, never arbitrary wallet/collateral snapshots.
-- Missing/conflicting resolutions, scripts and cost models fail explicitly.
usedCostModels :: Parameters -> [Utxo] -> Transaction -> IO (Either Error Models.CostModels)
usedCostModels parameters resolved transaction = runExceptT $ do
  table <- except (snapshotTable resolved)
  let body = Body.toBody (Tx.body transaction)
      fields = Body.bodyFields body
      nested = fromMaybe [] (Body.bodySubTransactions body)
      allFields = fields : map (SubBody.fields . SubBody.toBody . Sub.body) nested
      relevant = Set.toList (Set.fromList (concatMap references allFields))
      witnessScripts =
        Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses transaction))
          <> concatMap (Witnesses.scripts . Witnesses.toWitnesses . Sub.witnesses) nested
  sources <- except (traverse (resolve table) relevant)
  spending <- except (traverse (resolve table) (Fields.fieldInputs fields))
  policies <- except (mintPolicies (Body.toCbor (Tx.body transaction)))
  let needed = Set.fromList (mapMaybe (paymentScript . Utxo.output) spending <> policies <> fieldScripts fields)
      provided = witnessScripts <> mapMaybe (Output.referenceScript . Utxo.output) sources
  hashed <- traverse hashScript provided
  languages <- except (traverse (languageFor (Map.fromList hashed)) (Set.toList needed))
  models <- except (traverse lookupModel (Set.toList (Set.fromList (catMaybes languages))))
  pure (Models.fromList models)
  where
    hashScript script = do
      digest <- ExceptT (Script.hash script)
      pure (digest, script)
    lookupModel language =
      maybe
        (Left (InvalidBuildingRequest "A required script language has no cost model"))
        Right
        (Parameters.parameterCostModels parameters >>= Models.lookup language)

snapshotTable :: [Utxo] -> Either Error (Map.Map Input.Input Utxo)
snapshotTable = List.foldl' add (Right Map.empty)
  where
    add result utxo = do
      table <- result
      case Map.lookup (Utxo.input utxo) table of
        Just previous -> do
          unless (previous == utxo) (Left (InvalidBuildingRequest "Conflicting script-resolution snapshots"))
          pure table
        Nothing -> Right (Map.insert (Utxo.input utxo) utxo table)

resolve :: Map.Map Input.Input Utxo -> Input.Input -> Either Error Utxo
resolve table reference = maybe (Left (InvalidBuildingRequest "A script-resolution input is missing")) Right (Map.lookup reference table)

references :: Fields.Fields -> [Input.Input]
references fields = Fields.fieldInputs fields <> fromMaybe [] (Fields.fieldReferenceInputs fields)

paymentScript :: Output.Output -> Maybe Credential.ScriptHash
paymentScript output = case Output.address output of
  Address.ShelleyAddress address -> credentialScript (Shelley.paymentCredential address)
  Address.ByronAddress _ -> Nothing
  Address.RewardAddress _ -> Nothing

credentialScript :: Credential.Credential purpose -> Maybe Credential.ScriptHash
credentialScript credential = case credential of
  Credential.KeyCredential _ -> Nothing
  Credential.ScriptCredential hash -> Just hash

-- Native walker visits only field14 guards, not the field24 account guard map.
fieldScripts :: Fields.Fields -> [Credential.ScriptHash]
fieldScripts fields =
  mapMaybe (credentialScript . Reward.credential . fst) (maybe [] Fields.entries (Fields.fieldWithdrawals fields))
    <> concatMap certificateScripts (maybe [] Certificates.toList (Fields.fieldCertificates fields))
    <> concatMap (\(voter, _, _) -> voterScripts voter) (maybe [] Voting.toList (Fields.fieldVotingProcedures fields))
    <> mapMaybe (proposalPolicy . Proposal.proposalAction) (maybe [] Proposal.toList (Fields.fieldProposalProcedures fields))
    <> mapMaybe credentialScript (fromMaybe [] (Fields.fieldGuards fields))

-- Registration0 carries no authorizing credential; registration7 does. Combined
-- certificates authorize the stake credential, not the delegated pool or DRep.
-- Committee hot authorization requires the cold credential. Do not use the hot
-- credential or constitution metadata/guardrails as additional cert purposes.
certificateScripts :: Certificate.Certificate -> [Credential.ScriptHash]
certificateScripts certificate = case certificate of
  Certificate.StakeRegistration _ -> []
  Certificate.StakeDeregistration stake -> script stake
  Certificate.StakeDelegation stake _ -> script stake
  Certificate.PoolRegistration _ -> []
  Certificate.PoolRetirement _ _ -> []
  Certificate.GenesisKeyDelegation {} -> []
  Certificate.MoveInstantaneousRewards _ -> []
  Certificate.Registration stake _ -> script stake
  Certificate.Unregistration stake _ -> script stake
  Certificate.VoteDelegation stake _ -> script stake
  Certificate.StakeVoteDelegation stake _ _ -> script stake
  Certificate.StakeRegistrationDelegation stake _ _ -> script stake
  Certificate.VoteRegistrationDelegation stake _ _ -> script stake
  Certificate.StakeVoteRegistrationDelegation stake _ _ _ -> script stake
  Certificate.AuthorizeCommitteeHot cold _ -> script cold
  Certificate.ResignCommitteeCold cold _ -> script cold
  Certificate.RegisterDRep drep _ _ -> script drep
  Certificate.UnregisterDRep drep _ -> script drep
  Certificate.UpdateDRep drep _ -> script drep
  where
    script credential = maybe [] pure (credentialScript credential)

voterScripts :: Voting.Voter -> [Credential.ScriptHash]
voterScripts voter = case voter of
  Voting.CommitteeVoter credential -> script credential
  Voting.DRepVoter credential -> script credential
  Voting.StakePoolVoter _ -> []
  where
    script credential = maybe [] pure (credentialScript credential)

proposalPolicy :: Action.Action -> Maybe Credential.ScriptHash
proposalPolicy action = case action of
  Action.ParameterChange _ _ policy -> policy
  Action.TreasuryWithdrawals _ policy -> policy
  Action.HardForkInitiation _ _ -> Nothing
  Action.NoConfidence _ -> Nothing
  Action.UpdateCommittee {} -> Nothing
  Action.NewConstitution _ _ -> Nothing
  Action.InfoAction -> Nothing

languageFor :: Map.Map Credential.ScriptHash Script.Script -> Credential.ScriptHash -> Either Error (Maybe Word8)
languageFor provided hash = case Map.lookup hash provided of
  Nothing -> Left (InvalidBuildingRequest "A required body script is missing")
  Just (Script.Native _) -> Right Nothing
  Just (Script.Plutus script) -> Right (Just (languageId (Plutus.version script)))

languageId :: Plutus.Version -> Word8
languageId version = case version of
  Plutus.V1 -> 0
  Plutus.V2 -> 1
  Plutus.V3 -> 2
  Plutus.V4 -> 3

-- The semantic Mint observer intentionally normalizes zero/empty policy maps.
-- Native needed-script traversal still counts their original keys, so read only
-- these keys from the exact body encoding while the validated asset maps are
-- skipped. No source bytes or ledger values are reconstructed or normalized.
mintPolicies :: ByteString -> Either Error [Credential.ScriptHash]
mintPolicies bodyBytes = do
  fields <- Cbor.decodeAs InvalidBuildingRequest (Cbor.mapFields bodyBytes) bodyBytes
  case Map.lookup 9 fields of
    Nothing -> Right []
    Just bytes -> Cbor.decodeAs InvalidBuildingRequest (mapM decodePolicy =<< Cbor.entries ((,) <$> D.decodeBytes <*> Cbor.slice bytes)) bytes
  where
    decodePolicy (bytes, _) = either (fail . show) pure (Credential.scriptHashFromBytes bytes)
