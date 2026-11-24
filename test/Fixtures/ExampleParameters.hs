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

-- | Synthetic protocol parameters for the offline subtransaction example.
module Fixtures.ExampleParameters (parameters) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as Ex
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.UnitInterval as Unit

-- DEFINITIONS ----------------------------------------------------------------

-- | Use a provider snapshot for real transactions; this fixture performs no Plutus evaluation.
parameters :: Either Error P.Parameters
parameters = do
  r <- Rational.mkNonNegativeRational 3 10
  u <- Unit.mkUnitInterval 1 5
  let ex = Ex.ExUnits 14000000 10000000000
      version = Version.ProtocolVersion 12 0
      prices = Prices.ExUnitPrices r r
  pure
    P.Parameters
      { P.parameterMinFeeA = 44,
        P.parameterMinFeeB = 155381,
        P.parameterMaxBlockBodySize = 90112,
        P.parameterMaxTxSize = 16384,
        P.parameterMaxBlockHeaderSize = 1100,
        P.parameterKeyDeposit = 2000000,
        P.parameterPoolDeposit = 500000000,
        P.parameterMaxEpoch = 18,
        P.parameterDesiredPoolCount = 500,
        P.parameterPoolPledgeInfluence = r,
        P.parameterExpansionRate = u,
        P.parameterTreasuryGrowthRate = u,
        P.parameterDecentralization = Nothing,
        P.parameterExtraEntropy = Nothing,
        P.parameterProtocolVersion = version,
        P.parameterMinPoolCost = 170000000,
        P.parameterAdaPerUtxoByte = Just 4310,
        P.parameterCostModels = Just Models.empty,
        P.parameterExecutionCosts = Just prices,
        P.parameterMaxTxExUnits = Just ex,
        P.parameterMaxBlockExUnits = Just ex,
        P.parameterMaxValueSize = Just 5000,
        P.parameterCollateralPercentage = Just 150,
        P.parameterMaxCollateralInputs = Just 3,
        P.parameterPoolVotingThresholds = Nothing,
        P.parameterDrepVotingThresholds = Nothing,
        P.parameterMinCommitteeSize = Nothing,
        P.parameterCommitteeTermLimit = Nothing,
        P.parameterGovernanceActionValidityPeriod = Nothing,
        P.parameterGovernanceActionDeposit = Nothing,
        P.parameterDrepDeposit = Nothing,
        P.parameterDrepInactivityPeriod = Nothing,
        P.parameterRefScriptCostPerByte = Nothing,
        P.parameterMaxRefScriptSizePerBlock = Nothing,
        P.parameterMaxRefScriptSizePerTx = Nothing,
        P.parameterRefScriptCostStride = Nothing,
        P.parameterRefScriptCostMultiplier = Nothing,
        P.parameterMaxPledgeLeverage = Nothing,
        P.parameterMinPoolMargin = Nothing,
        P.parameterLeiosAnnouncementPeriodLength = Nothing,
        P.parameterLeiosVotePeriodLength = Nothing,
        P.parameterLeiosDiffusionPeriodLength = Nothing,
        P.parameterLeiosCommitteeSize = Nothing,
        P.parameterLeiosQuorumStakeThreshold = Nothing,
        P.parameterMaxEndorserBlockReferencesSize = Nothing,
        P.parameterMaxEndorserBlockTxsSize = Nothing,
        P.parameterMaxEndorserBlockExecutionUnits = Nothing,
        P.parameterMaxRefScriptSizePerEndorserBlock = Nothing,
        P.parameterPerasMinCandidateBlockAge = Nothing,
        P.parameterPerasHealingFactor = Nothing,
        P.parameterPerasCertBoost = Nothing,
        P.parameterPerasTargetCommitteeSize = Nothing,
        P.parameterPerasBootstrapRound = Nothing,
        P.parameterPerasQuorumThresholdSafetyMargin = Nothing,
        P.parameterRefInputsCostPerMultiAssetPolicy = Nothing,
        P.parameterRefInputsCostPerDatumByte = Nothing
      }
