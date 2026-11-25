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

-- | Normalize Ogmios field names without rounding exact ratios.
module Cometa.Provider.Internal.Protocol (decodeParameters, decodeHydraParameters) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Provider.Blockfrost.Internal.Json as Json
import qualified Cometa.Provider.Blockfrost.Internal.Protocol as Common
import Control.Monad (foldM, unless)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, withObject)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text

-- DEFINITIONS ----------------------------------------------------------------

decodeParameters :: Value -> Either Error P.Parameters
decodeParameters value = do
  (normalized, block, tx, stride, multiplier) <- Json.parseValue "provider.protocolParameters" parser value
  parameters <- Common.decodeProtocolParameters normalized
  pure
    parameters
      { P.parameterMaxRefScriptSizePerBlock = block,
        P.parameterMaxRefScriptSizePerTx = tx,
        P.parameterRefScriptCostStride = Just stride,
        P.parameterRefScriptCostMultiplier = Just multiplier
      }
  where
    parser source = do
      fields <- traverse (\(name, path) -> (,) (Key.fromText name) <$> at source path) mapping
      models <- at source ["plutusCostModels"] >>= withObject "cost models" (traverse model . KM.toList)
      stride <- at source ["minFeeReferenceScripts", "range"] >>= Common.integer >>= checked . P.mkReferenceScriptCostStride
      multiplier <- at source ["minFeeReferenceScripts", "multiplier"] >>= Common.fraction
      block <- optionalBytes source "maxReferenceScriptsSizePerBlock"
      tx <- optionalBytes source "maxReferenceScriptsSizePerTransaction"
      pure (Object (KM.fromList (("cost_models_raw", Object (KM.fromList models)) : fields)), block, tx, stride, multiplier)
    key = Key.fromText
    at source [] = pure source
    at source (part : rest) = withObject "protocol parameters" (maybe (fail "Missing parameter") (`at` rest) . KM.lookup (key part)) source
    optionalBytes source name =
      withObject
        "protocol parameters"
        ( \o -> case KM.lookup (key name) o of
            Nothing -> pure Nothing
            Just v -> Just <$> (at v ["bytes"] >>= Common.bounded)
        )
        source
    model (language, costs) = do
      let names = [("plutus:v1", "PlutusV1"), ("plutus:v2", "PlutusV2"), ("plutus:v3", "PlutusV3"), ("plutus:v4", "PlutusV4")]
      name <- maybe (fail "Unknown script language") pure (lookup language names)
      pure (name, costs)
    checked = either (const (fail "Invalid parameter")) pure

mapping :: [(Text, [Text])]
mapping =
  [ ("protocol_major_ver", ["version", "major"]),
    ("protocol_minor_ver", ["version", "minor"]),
    ("min_fee_a", ["minFeeCoefficient"]),
    ("min_fee_b", ["minFeeConstant", "ada", "lovelace"]),
    ("max_block_size", ["maxBlockBodySize", "bytes"]),
    ("max_tx_size", ["maxTransactionSize", "bytes"]),
    ("max_block_header_size", ["maxBlockHeaderSize", "bytes"]),
    ("key_deposit", ["stakeCredentialDeposit", "ada", "lovelace"]),
    ("pool_deposit", ["stakePoolDeposit", "ada", "lovelace"]),
    ("e_max", ["stakePoolRetirementEpochBound"]),
    ("n_opt", ["desiredNumberOfStakePools"]),
    ("a0", ["stakePoolPledgeInfluence"]),
    ("rho", ["monetaryExpansion"]),
    ("tau", ["treasuryExpansion"]),
    ("min_pool_cost", ["minStakePoolCost", "ada", "lovelace"]),
    ("coins_per_utxo_size", ["minUtxoDepositCoefficient"]),
    ("price_mem", ["scriptExecutionPrices", "memory"]),
    ("price_step", ["scriptExecutionPrices", "cpu"]),
    ("max_tx_ex_mem", ["maxExecutionUnitsPerTransaction", "memory"]),
    ("max_tx_ex_steps", ["maxExecutionUnitsPerTransaction", "cpu"]),
    ("max_block_ex_mem", ["maxExecutionUnitsPerBlock", "memory"]),
    ("max_block_ex_steps", ["maxExecutionUnitsPerBlock", "cpu"]),
    ("max_val_size", ["maxValueSize", "bytes"]),
    ("collateral_percent", ["collateralPercentage"]),
    ("max_collateral_inputs", ["maxCollateralInputs"]),
    ("committee_min_size", ["constitutionalCommitteeMinSize"]),
    ("committee_max_term_length", ["constitutionalCommitteeMaxTermLength"]),
    ("gov_action_lifetime", ["governanceActionLifetime"]),
    ("gov_action_deposit", ["governanceActionDeposit", "ada", "lovelace"]),
    ("drep_deposit", ["delegateRepresentativeDeposit", "ada", "lovelace"]),
    ("drep_activity", ["delegateRepresentativeMaxIdleTime"]),
    ("min_fee_ref_script_cost_per_byte", ["minFeeReferenceScripts", "base"]),
    ("pvt_motion_no_confidence", ["stakePoolVotingThresholds", "noConfidence"]),
    ("pvt_committee_normal", ["stakePoolVotingThresholds", "constitutionalCommittee", "default"]),
    ("pvt_committee_no_confidence", ["stakePoolVotingThresholds", "constitutionalCommittee", "stateOfNoConfidence"]),
    ("pvt_hard_fork_initiation", ["stakePoolVotingThresholds", "hardForkInitiation"]),
    ("pvt_p_p_security_group", ["stakePoolVotingThresholds", "protocolParametersUpdate", "security"]),
    ("dvt_motion_no_confidence", ["delegateRepresentativeVotingThresholds", "noConfidence"]),
    ("dvt_committee_normal", ["delegateRepresentativeVotingThresholds", "constitutionalCommittee", "default"]),
    ("dvt_committee_no_confidence", ["delegateRepresentativeVotingThresholds", "constitutionalCommittee", "stateOfNoConfidence"]),
    ("dvt_update_to_constitution", ["delegateRepresentativeVotingThresholds", "constitution"]),
    ("dvt_hard_fork_initiation", ["delegateRepresentativeVotingThresholds", "hardForkInitiation"]),
    ("dvt_p_p_network_group", ["delegateRepresentativeVotingThresholds", "protocolParametersUpdate", "network"]),
    ("dvt_p_p_economic_group", ["delegateRepresentativeVotingThresholds", "protocolParametersUpdate", "economic"]),
    ("dvt_p_p_technical_group", ["delegateRepresentativeVotingThresholds", "protocolParametersUpdate", "technical"]),
    ("dvt_p_p_gov_group", ["delegateRepresentativeVotingThresholds", "protocolParametersUpdate", "governance"]),
    ("dvt_treasury_withdrawal", ["delegateRepresentativeVotingThresholds", "treasuryWithdrawals"])
  ]

-- | Hydra exposes the Cardano CLI parameter format. Conway's tier constants
-- are ledger constants, absent from that JSON. Reject newer eras explicitly.
decodeHydraParameters :: Value -> Either Error P.Parameters
decodeHydraParameters source = do
  normalized <- Json.parseValue "hydra.protocolParameters" normalize source
  decodeParameters normalized
  where
    normalize value = do
      fields <- traverse (\(target, path) -> (,) (Text.splitOn "." target) <$> at value (Text.splitOn "." path)) hydraMapping
      result <- foldM (\o (path, v) -> insertPath path v o) (Object KM.empty) fields
      version <- at value ["protocolVersion", "major"] >>= Common.integer
      unless (version >= 9 && version <= 11) (fail "Unsupported Hydra ledger version")
      models <- at value ["costModels"] >>= withObject "models" (traverse model . KM.toList)
      withModels <- insertPath ["plutusCostModels"] (Object (KM.fromList models)) result
      withRange <- insertPath ["minFeeReferenceScripts", "range"] (Number 25600) withModels
      insertPath ["minFeeReferenceScripts", "multiplier"] (String "6/5") withRange
    at value [] = pure value
    at value (key : rest) = withObject "parameter" (maybe (fail "Missing parameter") (`at` rest) . KM.lookup (Key.fromText key)) value
    model (key, costs) = case lookup key [("PlutusV1", "plutus:v1"), ("PlutusV2", "plutus:v2"), ("PlutusV3", "plutus:v3")] of
      Nothing -> fail "Unsupported Hydra script language"
      Just language -> pure (language, costs)

insertPath :: [Text] -> Value -> Value -> Parser Value
insertPath [] value = const (pure value)
insertPath (key : rest) value = withObject "parameters" $ \o -> do
  let name = Key.fromText key
  child <- insertPath rest value (fromMaybe (Object KM.empty) (KM.lookup name o))
  pure (Object (KM.insert name child o))

hydraMapping :: [(Text, Text)]
hydraMapping =
  [ ("minFeeCoefficient", "txFeePerByte"),
    ("minFeeConstant.ada.lovelace", "txFeeFixed"),
    ("maxBlockBodySize.bytes", "maxBlockBodySize"),
    ("maxTransactionSize.bytes", "maxTxSize"),
    ("maxBlockHeaderSize.bytes", "maxBlockHeaderSize"),
    ("stakeCredentialDeposit.ada.lovelace", "stakeAddressDeposit"),
    ("stakePoolDeposit.ada.lovelace", "stakePoolDeposit"),
    ("stakePoolRetirementEpochBound", "poolRetireMaxEpoch"),
    ("desiredNumberOfStakePools", "stakePoolTargetNum"),
    ("stakePoolPledgeInfluence", "poolPledgeInfluence"),
    ("monetaryExpansion", "monetaryExpansion"),
    ("treasuryExpansion", "treasuryCut"),
    ("minStakePoolCost.ada.lovelace", "minPoolCost"),
    ("minUtxoDepositCoefficient", "utxoCostPerByte"),
    ("scriptExecutionPrices.memory", "executionUnitPrices.priceMemory"),
    ("scriptExecutionPrices.cpu", "executionUnitPrices.priceSteps"),
    ("maxExecutionUnitsPerTransaction.memory", "maxTxExecutionUnits.memory"),
    ("maxExecutionUnitsPerTransaction.cpu", "maxTxExecutionUnits.steps"),
    ("maxExecutionUnitsPerBlock.memory", "maxBlockExecutionUnits.memory"),
    ("maxExecutionUnitsPerBlock.cpu", "maxBlockExecutionUnits.steps"),
    ("maxValueSize.bytes", "maxValueSize"),
    ("collateralPercentage", "collateralPercentage"),
    ("maxCollateralInputs", "maxCollateralInputs"),
    ("version.major", "protocolVersion.major"),
    ("version.minor", "protocolVersion.minor"),
    ("constitutionalCommitteeMinSize", "committeeMinSize"),
    ("constitutionalCommitteeMaxTermLength", "committeeMaxTermLength"),
    ("governanceActionLifetime", "govActionLifetime"),
    ("governanceActionDeposit.ada.lovelace", "govActionDeposit"),
    ("delegateRepresentativeDeposit.ada.lovelace", "dRepDeposit"),
    ("delegateRepresentativeMaxIdleTime", "dRepActivity"),
    ("minFeeReferenceScripts.base", "minFeeRefScriptCostPerByte"),
    ("stakePoolVotingThresholds.noConfidence", "poolVotingThresholds.motionNoConfidence"),
    ("stakePoolVotingThresholds.constitutionalCommittee.default", "poolVotingThresholds.committeeNormal"),
    ("stakePoolVotingThresholds.constitutionalCommittee.stateOfNoConfidence", "poolVotingThresholds.committeeNoConfidence"),
    ("stakePoolVotingThresholds.hardForkInitiation", "poolVotingThresholds.hardForkInitiation"),
    ("stakePoolVotingThresholds.protocolParametersUpdate.security", "poolVotingThresholds.ppSecurityGroup"),
    ("delegateRepresentativeVotingThresholds.noConfidence", "dRepVotingThresholds.motionNoConfidence"),
    ("delegateRepresentativeVotingThresholds.constitutionalCommittee.default", "dRepVotingThresholds.committeeNormal"),
    ("delegateRepresentativeVotingThresholds.constitutionalCommittee.stateOfNoConfidence", "dRepVotingThresholds.committeeNoConfidence"),
    ("delegateRepresentativeVotingThresholds.hardForkInitiation", "dRepVotingThresholds.hardForkInitiation"),
    ("delegateRepresentativeVotingThresholds.constitution", "dRepVotingThresholds.updateToConstitution"),
    ("delegateRepresentativeVotingThresholds.treasuryWithdrawals", "dRepVotingThresholds.treasuryWithdrawal"),
    ("delegateRepresentativeVotingThresholds.protocolParametersUpdate.network", "dRepVotingThresholds.ppNetworkGroup"),
    ("delegateRepresentativeVotingThresholds.protocolParametersUpdate.economic", "dRepVotingThresholds.ppEconomicGroup"),
    ("delegateRepresentativeVotingThresholds.protocolParametersUpdate.technical", "dRepVotingThresholds.ppTechnicalGroup"),
    ("delegateRepresentativeVotingThresholds.protocolParametersUpdate.governance", "dRepVotingThresholds.ppGovGroup")
  ]
