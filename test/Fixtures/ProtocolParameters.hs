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

-- | Deterministic field-coverage data; these are not parameters for a live network.
module Fixtures.ProtocolParameters (parameters) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.DRepVotingThresholds as DRep
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as Ex
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.PoolVotingThresholds as Pool
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.UnitInterval as Unit
import qualified Data.ByteString as BS

-- DEFINITIONS ----------------------------------------------------------------

-- | Validated full-field snapshot shared by conversion and callback tests.
parameters :: Either Error P.Parameters
parameters = do
  r <- Rational.mkNonNegativeRational 7 3
  u <- Unit.mkUnitInterval 2 3
  stride <- P.mkReferenceScriptCostStride 4294967295
  nonce <- P.mkNonce (BS.pack [0 .. 31])
  let ex = Ex.ExUnits maxBound 123456789
      version = Version.ProtocolVersion 12 maxBound
      prices = Prices.ExUnitPrices r r
      pool = Pool.PoolVotingThresholds u u u u u
      drep = DRep.DRepVotingThresholds u u u u u u u u u u
  pure
    P.Parameters
      { P.parameterMinFeeA = 100,
        P.parameterMinFeeB = 101,
        P.parameterMaxBlockBodySize = 102,
        P.parameterMaxTxSize = 103,
        P.parameterMaxBlockHeaderSize = 104,
        P.parameterKeyDeposit = 105,
        P.parameterPoolDeposit = 106,
        P.parameterMaxEpoch = 107,
        P.parameterDesiredPoolCount = 108,
        P.parameterPoolPledgeInfluence = r,
        P.parameterExpansionRate = u,
        P.parameterTreasuryGrowthRate = u,
        P.parameterDecentralization = Just u,
        P.parameterExtraEntropy = Just nonce,
        P.parameterProtocolVersion = version,
        P.parameterMinPoolCost = 116,
        P.parameterAdaPerUtxoByte = Just 117,
        P.parameterCostModels = Just Models.empty,
        P.parameterExecutionCosts = Just prices,
        P.parameterMaxTxExUnits = Just ex,
        P.parameterMaxBlockExUnits = Just ex,
        P.parameterMaxValueSize = Just 122,
        P.parameterCollateralPercentage = Just 123,
        P.parameterMaxCollateralInputs = Just 124,
        P.parameterPoolVotingThresholds = Just pool,
        P.parameterDrepVotingThresholds = Just drep,
        P.parameterMinCommitteeSize = Just 127,
        P.parameterCommitteeTermLimit = Just 128,
        P.parameterGovernanceActionValidityPeriod = Just 129,
        P.parameterGovernanceActionDeposit = Just 130,
        P.parameterDrepDeposit = Just 131,
        P.parameterDrepInactivityPeriod = Just 132,
        P.parameterRefScriptCostPerByte = Just r,
        P.parameterMaxRefScriptSizePerBlock = Just 134,
        P.parameterMaxRefScriptSizePerTx = Just 135,
        P.parameterRefScriptCostStride = Just stride,
        P.parameterRefScriptCostMultiplier = Just r,
        P.parameterMaxPledgeLeverage = Just (Just r),
        P.parameterMinPoolMargin = Just u,
        P.parameterLeiosAnnouncementPeriodLength = Just 140,
        P.parameterLeiosVotePeriodLength = Just 141,
        P.parameterLeiosDiffusionPeriodLength = Just 142,
        P.parameterLeiosCommitteeSize = Just 143,
        P.parameterLeiosQuorumStakeThreshold = Just u,
        P.parameterMaxEndorserBlockReferencesSize = Just 145,
        P.parameterMaxEndorserBlockTxsSize = Just 146,
        P.parameterMaxEndorserBlockExecutionUnits = Just ex,
        P.parameterMaxRefScriptSizePerEndorserBlock = Just 148,
        P.parameterPerasMinCandidateBlockAge = Just 149,
        P.parameterPerasHealingFactor = Just r,
        P.parameterPerasCertBoost = Just 151,
        P.parameterPerasTargetCommitteeSize = Just 152,
        P.parameterPerasBootstrapRound = Just (Just maxBound),
        P.parameterPerasQuorumThresholdSafetyMargin = Just u,
        P.parameterRefInputsCostPerMultiAssetPolicy = Just 155,
        P.parameterRefInputsCostPerDatumByte = Just 156
      }
