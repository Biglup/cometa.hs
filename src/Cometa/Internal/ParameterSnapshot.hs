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

-- | Private complete parameter snapshots and native-representability checks.
-- Wire maps reuse protocol-update keys while requiring every nonoptional snapshot
-- field. A sparse update is never completed with invented defaults.
module Cometa.Internal.ParameterSnapshot (encodeSnapshot, decodeSnapshot, validateNative) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Protocol.Parameters (Parameters (..))
import qualified Cometa.Protocol.Parameters.Update as Update
import Data.ByteString (ByteString)
import Data.Int (Int64)

-- DEFINITIONS ----------------------------------------------------------------

encodeSnapshot :: Parameters -> ByteString
encodeSnapshot = Update.encodeCbor . Update.fromParameters

decodeSnapshot :: ByteString -> Either Error Parameters
decodeSnapshot bytes = do
  change <- Update.toUpdate <$> Update.decodeCbor bytes
  Parameters
    <$> required (Update.updateMinFeeA change)
    <*> required (Update.updateMinFeeB change)
    <*> required (Update.updateMaxBlockBodySize change)
    <*> required (Update.updateMaxTxSize change)
    <*> required (Update.updateMaxBlockHeaderSize change)
    <*> required (Update.updateKeyDeposit change)
    <*> required (Update.updatePoolDeposit change)
    <*> required (Update.updateMaxEpoch change)
    <*> required (Update.updateDesiredPoolCount change)
    <*> required (Update.updatePoolPledgeInfluence change)
    <*> required (Update.updateExpansionRate change)
    <*> required (Update.updateTreasuryGrowthRate change)
    <*> pure (Update.updateDecentralization change)
    <*> pure (Update.updateExtraEntropy change)
    <*> required (Update.updateProtocolVersion change)
    <*> required (Update.updateMinPoolCost change)
    <*> pure (Update.updateAdaPerUtxoByte change)
    <*> pure (Update.updateCostModels change)
    <*> pure (Update.updateExecutionCosts change)
    <*> pure (Update.updateMaxTxExUnits change)
    <*> pure (Update.updateMaxBlockExUnits change)
    <*> pure (Update.updateMaxValueSize change)
    <*> pure (Update.updateCollateralPercentage change)
    <*> pure (Update.updateMaxCollateralInputs change)
    <*> pure (Update.updatePoolVotingThresholds change)
    <*> pure (Update.updateDrepVotingThresholds change)
    <*> pure (Update.updateMinCommitteeSize change)
    <*> pure (Update.updateCommitteeTermLimit change)
    <*> pure (Update.updateGovernanceActionValidityPeriod change)
    <*> pure (Update.updateGovernanceActionDeposit change)
    <*> pure (Update.updateDrepDeposit change)
    <*> pure (Update.updateDrepInactivityPeriod change)
    <*> pure (Update.updateRefScriptCostPerByte change)
    <*> pure (Update.updateMaxRefScriptSizePerBlock change)
    <*> pure (Update.updateMaxRefScriptSizePerTx change)
    <*> pure (Update.updateRefScriptCostStride change)
    <*> pure (Update.updateRefScriptCostMultiplier change)
    <*> pure (Update.updateMaxPledgeLeverage change)
    <*> pure (Update.updateMinPoolMargin change)
    <*> pure (Update.updateLeiosAnnouncementPeriodLength change)
    <*> pure (Update.updateLeiosVotePeriodLength change)
    <*> pure (Update.updateLeiosDiffusionPeriodLength change)
    <*> pure (Update.updateLeiosCommitteeSize change)
    <*> pure (Update.updateLeiosQuorumStakeThreshold change)
    <*> pure (Update.updateMaxEndorserBlockReferencesSize change)
    <*> pure (Update.updateMaxEndorserBlockTxsSize change)
    <*> pure (Update.updateMaxEndorserBlockExecutionUnits change)
    <*> pure (Update.updateMaxRefScriptSizePerEndorserBlock change)
    <*> pure (Update.updatePerasMinCandidateBlockAge change)
    <*> pure (Update.updatePerasHealingFactor change)
    <*> pure (Update.updatePerasCertBoost change)
    <*> pure (Update.updatePerasTargetCommitteeSize change)
    <*> pure (Update.updatePerasBootstrapRound change)
    <*> pure (Update.updatePerasQuorumThresholdSafetyMargin change)
    <*> pure (Update.updateRefInputsCostPerMultiAssetPolicy change)
    <*> pure (Update.updateRefInputsCostPerDatumByte change)
  where
    required = maybe (Left (InvalidParameterSnapshot "Missing required protocol snapshot field")) Right

-- | The pinned native full-parameter setter accepts a signed max-value size.
-- Reject unsupported narrowing before entering C; the pure snapshot domain
-- remains capable of representing the complete protocol uint64 field.
validateNative :: Parameters -> Either Error ()
validateNative parameters = case parameterMaxValueSize parameters of
  Just value | value > fromIntegral (maxBound :: Int64) -> Left (InvalidParameterSnapshot "Maximum value size exceeds native signed setter range")
  _ -> Right ()
