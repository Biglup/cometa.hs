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

-- | Sparse typed changes to protocol parameters. 'Nothing' leaves a field
-- unchanged. For nullable leverage and bootstrap round, @Just Nothing@ explicitly
-- removes the bound or round. The original imported encoding is available
-- separately from fresh serialization, which may normalize representation.
--
-- @
-- import qualified Cometa.Protocol.Parameters.Update as Update
--
-- change :: Update.Update
-- change = Update.empty { Update.updateMinFeeB = Just 155381 }
-- @
module Cometa.Protocol.Parameters.Update
  ( Update (..),
    empty,
    apply,
    fromParameters,
    EncodedUpdate,
    encodeCbor,
    decodeCbor,
    toCbor,
    toUpdate,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import Cometa.Error (Error (..))
import Cometa.Internal.CostModels (CostModels)
import qualified Cometa.Internal.CostModels as Models
import Cometa.Internal.ProtocolValues (DRepVotingThresholds, ExUnitPrices, ExUnits, NonNegativeRational, PoolVotingThresholds, ProtocolVersion, UnitInterval)
import qualified Cometa.Internal.ProtocolValues as Values
import Cometa.Protocol.Parameters (Nonce, Parameters (..), ReferenceScriptCostStride)
import qualified Cometa.Protocol.Parameters as Parameters
import Control.Applicative ((<|>))
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Word (Word16, Word32, Word64)

-- TYPES ----------------------------------------------------------------------

-- | Independent optional changes. All constituent values are validated once;
-- constructing or applying a change is pure and cannot fail. Construction
-- does not validate activation or governance rules of a particular ledger era.
data Update = Update
  { -- | Linear transaction fee coefficient in lovelace per byte.
    updateMinFeeA :: !(Maybe Word64),
    -- | Constant transaction fee in lovelace.
    updateMinFeeB :: !(Maybe Word64),
    -- | Maximum block body size in bytes.
    updateMaxBlockBodySize :: !(Maybe Word64),
    -- | Maximum transaction size in bytes.
    updateMaxTxSize :: !(Maybe Word64),
    -- | Maximum block header size in bytes.
    updateMaxBlockHeaderSize :: !(Maybe Word64),
    -- | Stake credential registration deposit in lovelace.
    updateKeyDeposit :: !(Maybe Word64),
    -- | Pool registration deposit in lovelace.
    updatePoolDeposit :: !(Maybe Word64),
    -- | Maximum pool retirement interval in epochs.
    updateMaxEpoch :: !(Maybe Word64),
    -- | Desired number of stake pools.
    updateDesiredPoolCount :: !(Maybe Word64),
    -- | Nonnegative pool pledge influence factor.
    updatePoolPledgeInfluence :: !(Maybe NonNegativeRational),
    -- | Monetary expansion fraction per epoch.
    updateExpansionRate :: !(Maybe UnitInterval),
    -- | Treasury growth fraction per epoch.
    updateTreasuryGrowthRate :: !(Maybe UnitInterval),
    -- | Decentralization fraction; deprecated after Alonzo.
    updateDecentralization :: !(Maybe UnitInterval),
    -- | Extra entropy nonce; deprecated after Alonzo.
    updateExtraEntropy :: !(Maybe Nonce),
    -- | Major and minor protocol version; updates deprecated after Babbage.
    updateProtocolVersion :: !(Maybe ProtocolVersion),
    -- | Minimum pool cost in lovelace per epoch.
    updateMinPoolCost :: !(Maybe Word64),
    -- | Minimum UTxO charge in lovelace per byte.
    updateAdaPerUtxoByte :: !(Maybe Word64),
    -- | Language-indexed execution cost models.
    updateCostModels :: !(Maybe CostModels),
    -- | Execution memory and step prices in lovelace per unit.
    updateExecutionCosts :: !(Maybe ExUnitPrices),
    -- | Maximum execution units per transaction.
    updateMaxTxExUnits :: !(Maybe ExUnits),
    -- | Maximum execution units per block.
    updateMaxBlockExUnits :: !(Maybe ExUnits),
    -- | Maximum serialized value size in bytes.
    updateMaxValueSize :: !(Maybe Word64),
    -- | Collateral as an integer percentage of script fees.
    updateCollateralPercentage :: !(Maybe Word64),
    -- | Maximum number of collateral inputs.
    updateMaxCollateralInputs :: !(Maybe Word64),
    -- | Stake pool governance voting thresholds.
    updatePoolVotingThresholds :: !(Maybe PoolVotingThresholds),
    -- | DRep governance voting thresholds.
    updateDrepVotingThresholds :: !(Maybe DRepVotingThresholds),
    -- | Minimum constitutional committee membership count.
    updateMinCommitteeSize :: !(Maybe Word64),
    -- | Maximum committee term in epochs.
    updateCommitteeTermLimit :: !(Maybe Word64),
    -- | Governance action lifetime in epochs.
    updateGovernanceActionValidityPeriod :: !(Maybe Word64),
    -- | Governance action deposit in lovelace.
    updateGovernanceActionDeposit :: !(Maybe Word64),
    -- | DRep registration deposit in lovelace.
    updateDrepDeposit :: !(Maybe Word64),
    -- | DRep inactivity interval in epochs.
    updateDrepInactivityPeriod :: !(Maybe Word64),
    -- | Base reference script charge in lovelace per byte.
    updateRefScriptCostPerByte :: !(Maybe NonNegativeRational),
    -- | Maximum reference script size per block in bytes; Dijkstra.
    updateMaxRefScriptSizePerBlock :: !(Maybe Word32),
    -- | Maximum reference script size per transaction in bytes; Dijkstra.
    updateMaxRefScriptSizePerTx :: !(Maybe Word32),
    -- | Positive reference script tier stride in bytes; Dijkstra.
    updateRefScriptCostStride :: !(Maybe ReferenceScriptCostStride),
    -- | Reference script tier multiplier; Dijkstra.
    updateRefScriptCostMultiplier :: !(Maybe NonNegativeRational),
    -- | Maximum pledge leverage; @Just Nothing@ selects an unbounded value.
    updateMaxPledgeLeverage :: !(Maybe (Maybe NonNegativeRational)),
    -- | Minimum stake pool profit margin fraction; Dijkstra.
    updateMinPoolMargin :: !(Maybe UnitInterval),
    -- | Leios announcement period in milliseconds.
    updateLeiosAnnouncementPeriodLength :: !(Maybe Word32),
    -- | Leios voting period in milliseconds.
    updateLeiosVotePeriodLength :: !(Maybe Word32),
    -- | Leios diffusion period in milliseconds.
    updateLeiosDiffusionPeriodLength :: !(Maybe Word32),
    -- | Leios committee member count.
    updateLeiosCommitteeSize :: !(Maybe Word16),
    -- | Leios quorum fraction of stake.
    updateLeiosQuorumStakeThreshold :: !(Maybe UnitInterval),
    -- | Maximum endorser block references size in bytes.
    updateMaxEndorserBlockReferencesSize :: !(Maybe Word32),
    -- | Maximum endorser block transactions size in bytes.
    updateMaxEndorserBlockTxsSize :: !(Maybe Word32),
    -- | Maximum execution units per endorser block.
    updateMaxEndorserBlockExecutionUnits :: !(Maybe ExUnits),
    -- | Maximum reference script size per endorser block in bytes.
    updateMaxRefScriptSizePerEndorserBlock :: !(Maybe Word32),
    -- | Minimum Peras candidate block age in slots.
    updatePerasMinCandidateBlockAge :: !(Maybe Word32),
    -- | Peras healing factor.
    updatePerasHealingFactor :: !(Maybe NonNegativeRational),
    -- | Peras certificate boost.
    updatePerasCertBoost :: !(Maybe Word16),
    -- | Target Peras committee member count.
    updatePerasTargetCommitteeSize :: !(Maybe Word16),
    -- | Manual Peras bootstrap round; @Just Nothing@ selects no round.
    updatePerasBootstrapRound :: !(Maybe (Maybe Word32)),
    -- | Peras quorum safety margin fraction.
    updatePerasQuorumThresholdSafetyMargin :: !(Maybe UnitInterval),
    -- | Reference input charge in lovelace per multi-asset policy.
    updateRefInputsCostPerMultiAssetPolicy :: !(Maybe Word64),
    -- | Reference input charge in lovelace per datum byte.
    updateRefInputsCostPerDatumByte :: !(Maybe Word64)
  }
  deriving (Eq, Show)

-- | A validated update with its exact original CBOR bytes. Equality and ordering
-- compare those bytes, so alternative encodings of the same change can differ.
data EncodedUpdate = EncodedUpdate !ByteString !Update deriving (Show)

instance Eq EncodedUpdate where
  EncodedUpdate a _ == EncodedUpdate b _ = a == b

instance Ord EncodedUpdate where
  compare (EncodedUpdate a _) (EncodedUpdate b _) = compare a b

-- CONSTRUCTION ---------------------------------------------------------------

-- | The empty change. Applying it preserves every parameter field.
empty :: Update
empty =
  Update
    { updateMinFeeA = Nothing,
      updateMinFeeB = Nothing,
      updateMaxBlockBodySize = Nothing,
      updateMaxTxSize = Nothing,
      updateMaxBlockHeaderSize = Nothing,
      updateKeyDeposit = Nothing,
      updatePoolDeposit = Nothing,
      updateMaxEpoch = Nothing,
      updateDesiredPoolCount = Nothing,
      updatePoolPledgeInfluence = Nothing,
      updateExpansionRate = Nothing,
      updateTreasuryGrowthRate = Nothing,
      updateDecentralization = Nothing,
      updateExtraEntropy = Nothing,
      updateProtocolVersion = Nothing,
      updateMinPoolCost = Nothing,
      updateAdaPerUtxoByte = Nothing,
      updateCostModels = Nothing,
      updateExecutionCosts = Nothing,
      updateMaxTxExUnits = Nothing,
      updateMaxBlockExUnits = Nothing,
      updateMaxValueSize = Nothing,
      updateCollateralPercentage = Nothing,
      updateMaxCollateralInputs = Nothing,
      updatePoolVotingThresholds = Nothing,
      updateDrepVotingThresholds = Nothing,
      updateMinCommitteeSize = Nothing,
      updateCommitteeTermLimit = Nothing,
      updateGovernanceActionValidityPeriod = Nothing,
      updateGovernanceActionDeposit = Nothing,
      updateDrepDeposit = Nothing,
      updateDrepInactivityPeriod = Nothing,
      updateRefScriptCostPerByte = Nothing,
      updateMaxRefScriptSizePerBlock = Nothing,
      updateMaxRefScriptSizePerTx = Nothing,
      updateRefScriptCostStride = Nothing,
      updateRefScriptCostMultiplier = Nothing,
      updateMaxPledgeLeverage = Nothing,
      updateMinPoolMargin = Nothing,
      updateLeiosAnnouncementPeriodLength = Nothing,
      updateLeiosVotePeriodLength = Nothing,
      updateLeiosDiffusionPeriodLength = Nothing,
      updateLeiosCommitteeSize = Nothing,
      updateLeiosQuorumStakeThreshold = Nothing,
      updateMaxEndorserBlockReferencesSize = Nothing,
      updateMaxEndorserBlockTxsSize = Nothing,
      updateMaxEndorserBlockExecutionUnits = Nothing,
      updateMaxRefScriptSizePerEndorserBlock = Nothing,
      updatePerasMinCandidateBlockAge = Nothing,
      updatePerasHealingFactor = Nothing,
      updatePerasCertBoost = Nothing,
      updatePerasTargetCommitteeSize = Nothing,
      updatePerasBootstrapRound = Nothing,
      updatePerasQuorumThresholdSafetyMargin = Nothing,
      updateRefInputsCostPerMultiAssetPolicy = Nothing,
      updateRefInputsCostPerDatumByte = Nothing
    }

-- | Apply all present fields to a complete snapshot, preserving absent fields.
apply :: Update -> Parameters -> Parameters
apply change current =
  Parameters
    { parameterMinFeeA = fromMaybe (parameterMinFeeA current) (updateMinFeeA change),
      parameterMinFeeB = fromMaybe (parameterMinFeeB current) (updateMinFeeB change),
      parameterMaxBlockBodySize = fromMaybe (parameterMaxBlockBodySize current) (updateMaxBlockBodySize change),
      parameterMaxTxSize = fromMaybe (parameterMaxTxSize current) (updateMaxTxSize change),
      parameterMaxBlockHeaderSize = fromMaybe (parameterMaxBlockHeaderSize current) (updateMaxBlockHeaderSize change),
      parameterKeyDeposit = fromMaybe (parameterKeyDeposit current) (updateKeyDeposit change),
      parameterPoolDeposit = fromMaybe (parameterPoolDeposit current) (updatePoolDeposit change),
      parameterMaxEpoch = fromMaybe (parameterMaxEpoch current) (updateMaxEpoch change),
      parameterDesiredPoolCount = fromMaybe (parameterDesiredPoolCount current) (updateDesiredPoolCount change),
      parameterPoolPledgeInfluence = fromMaybe (parameterPoolPledgeInfluence current) (updatePoolPledgeInfluence change),
      parameterExpansionRate = fromMaybe (parameterExpansionRate current) (updateExpansionRate change),
      parameterTreasuryGrowthRate = fromMaybe (parameterTreasuryGrowthRate current) (updateTreasuryGrowthRate change),
      parameterDecentralization = updateDecentralization change <|> parameterDecentralization current,
      parameterExtraEntropy = updateExtraEntropy change <|> parameterExtraEntropy current,
      parameterProtocolVersion = fromMaybe (parameterProtocolVersion current) (updateProtocolVersion change),
      parameterMinPoolCost = fromMaybe (parameterMinPoolCost current) (updateMinPoolCost change),
      parameterAdaPerUtxoByte = updateAdaPerUtxoByte change <|> parameterAdaPerUtxoByte current,
      parameterCostModels = updateCostModels change <|> parameterCostModels current,
      parameterExecutionCosts = updateExecutionCosts change <|> parameterExecutionCosts current,
      parameterMaxTxExUnits = updateMaxTxExUnits change <|> parameterMaxTxExUnits current,
      parameterMaxBlockExUnits = updateMaxBlockExUnits change <|> parameterMaxBlockExUnits current,
      parameterMaxValueSize = updateMaxValueSize change <|> parameterMaxValueSize current,
      parameterCollateralPercentage = updateCollateralPercentage change <|> parameterCollateralPercentage current,
      parameterMaxCollateralInputs = updateMaxCollateralInputs change <|> parameterMaxCollateralInputs current,
      parameterPoolVotingThresholds = updatePoolVotingThresholds change <|> parameterPoolVotingThresholds current,
      parameterDrepVotingThresholds = updateDrepVotingThresholds change <|> parameterDrepVotingThresholds current,
      parameterMinCommitteeSize = updateMinCommitteeSize change <|> parameterMinCommitteeSize current,
      parameterCommitteeTermLimit = updateCommitteeTermLimit change <|> parameterCommitteeTermLimit current,
      parameterGovernanceActionValidityPeriod = updateGovernanceActionValidityPeriod change <|> parameterGovernanceActionValidityPeriod current,
      parameterGovernanceActionDeposit = updateGovernanceActionDeposit change <|> parameterGovernanceActionDeposit current,
      parameterDrepDeposit = updateDrepDeposit change <|> parameterDrepDeposit current,
      parameterDrepInactivityPeriod = updateDrepInactivityPeriod change <|> parameterDrepInactivityPeriod current,
      parameterRefScriptCostPerByte = updateRefScriptCostPerByte change <|> parameterRefScriptCostPerByte current,
      parameterMaxRefScriptSizePerBlock = updateMaxRefScriptSizePerBlock change <|> parameterMaxRefScriptSizePerBlock current,
      parameterMaxRefScriptSizePerTx = updateMaxRefScriptSizePerTx change <|> parameterMaxRefScriptSizePerTx current,
      parameterRefScriptCostStride = updateRefScriptCostStride change <|> parameterRefScriptCostStride current,
      parameterRefScriptCostMultiplier = updateRefScriptCostMultiplier change <|> parameterRefScriptCostMultiplier current,
      parameterMaxPledgeLeverage = updateMaxPledgeLeverage change <|> parameterMaxPledgeLeverage current,
      parameterMinPoolMargin = updateMinPoolMargin change <|> parameterMinPoolMargin current,
      parameterLeiosAnnouncementPeriodLength = updateLeiosAnnouncementPeriodLength change <|> parameterLeiosAnnouncementPeriodLength current,
      parameterLeiosVotePeriodLength = updateLeiosVotePeriodLength change <|> parameterLeiosVotePeriodLength current,
      parameterLeiosDiffusionPeriodLength = updateLeiosDiffusionPeriodLength change <|> parameterLeiosDiffusionPeriodLength current,
      parameterLeiosCommitteeSize = updateLeiosCommitteeSize change <|> parameterLeiosCommitteeSize current,
      parameterLeiosQuorumStakeThreshold = updateLeiosQuorumStakeThreshold change <|> parameterLeiosQuorumStakeThreshold current,
      parameterMaxEndorserBlockReferencesSize = updateMaxEndorserBlockReferencesSize change <|> parameterMaxEndorserBlockReferencesSize current,
      parameterMaxEndorserBlockTxsSize = updateMaxEndorserBlockTxsSize change <|> parameterMaxEndorserBlockTxsSize current,
      parameterMaxEndorserBlockExecutionUnits = updateMaxEndorserBlockExecutionUnits change <|> parameterMaxEndorserBlockExecutionUnits current,
      parameterMaxRefScriptSizePerEndorserBlock = updateMaxRefScriptSizePerEndorserBlock change <|> parameterMaxRefScriptSizePerEndorserBlock current,
      parameterPerasMinCandidateBlockAge = updatePerasMinCandidateBlockAge change <|> parameterPerasMinCandidateBlockAge current,
      parameterPerasHealingFactor = updatePerasHealingFactor change <|> parameterPerasHealingFactor current,
      parameterPerasCertBoost = updatePerasCertBoost change <|> parameterPerasCertBoost current,
      parameterPerasTargetCommitteeSize = updatePerasTargetCommitteeSize change <|> parameterPerasTargetCommitteeSize current,
      parameterPerasBootstrapRound = updatePerasBootstrapRound change <|> parameterPerasBootstrapRound current,
      parameterPerasQuorumThresholdSafetyMargin = updatePerasQuorumThresholdSafetyMargin change <|> parameterPerasQuorumThresholdSafetyMargin current,
      parameterRefInputsCostPerMultiAssetPolicy = updateRefInputsCostPerMultiAssetPolicy change <|> parameterRefInputsCostPerMultiAssetPolicy current,
      parameterRefInputsCostPerDatumByte = updateRefInputsCostPerDatumByte change <|> parameterRefInputsCostPerDatumByte current
    }

-- | Produce a change setting each available field, including explicit nulls.
-- Unavailable fields are omitted.
fromParameters :: Parameters -> Update
fromParameters current =
  Update
    { updateMinFeeA = Just (parameterMinFeeA current),
      updateMinFeeB = Just (parameterMinFeeB current),
      updateMaxBlockBodySize = Just (parameterMaxBlockBodySize current),
      updateMaxTxSize = Just (parameterMaxTxSize current),
      updateMaxBlockHeaderSize = Just (parameterMaxBlockHeaderSize current),
      updateKeyDeposit = Just (parameterKeyDeposit current),
      updatePoolDeposit = Just (parameterPoolDeposit current),
      updateMaxEpoch = Just (parameterMaxEpoch current),
      updateDesiredPoolCount = Just (parameterDesiredPoolCount current),
      updatePoolPledgeInfluence = Just (parameterPoolPledgeInfluence current),
      updateExpansionRate = Just (parameterExpansionRate current),
      updateTreasuryGrowthRate = Just (parameterTreasuryGrowthRate current),
      updateDecentralization = parameterDecentralization current,
      updateExtraEntropy = parameterExtraEntropy current,
      updateProtocolVersion = Just (parameterProtocolVersion current),
      updateMinPoolCost = Just (parameterMinPoolCost current),
      updateAdaPerUtxoByte = parameterAdaPerUtxoByte current,
      updateCostModels = parameterCostModels current,
      updateExecutionCosts = parameterExecutionCosts current,
      updateMaxTxExUnits = parameterMaxTxExUnits current,
      updateMaxBlockExUnits = parameterMaxBlockExUnits current,
      updateMaxValueSize = parameterMaxValueSize current,
      updateCollateralPercentage = parameterCollateralPercentage current,
      updateMaxCollateralInputs = parameterMaxCollateralInputs current,
      updatePoolVotingThresholds = parameterPoolVotingThresholds current,
      updateDrepVotingThresholds = parameterDrepVotingThresholds current,
      updateMinCommitteeSize = parameterMinCommitteeSize current,
      updateCommitteeTermLimit = parameterCommitteeTermLimit current,
      updateGovernanceActionValidityPeriod = parameterGovernanceActionValidityPeriod current,
      updateGovernanceActionDeposit = parameterGovernanceActionDeposit current,
      updateDrepDeposit = parameterDrepDeposit current,
      updateDrepInactivityPeriod = parameterDrepInactivityPeriod current,
      updateRefScriptCostPerByte = parameterRefScriptCostPerByte current,
      updateMaxRefScriptSizePerBlock = parameterMaxRefScriptSizePerBlock current,
      updateMaxRefScriptSizePerTx = parameterMaxRefScriptSizePerTx current,
      updateRefScriptCostStride = parameterRefScriptCostStride current,
      updateRefScriptCostMultiplier = parameterRefScriptCostMultiplier current,
      updateMaxPledgeLeverage = parameterMaxPledgeLeverage current,
      updateMinPoolMargin = parameterMinPoolMargin current,
      updateLeiosAnnouncementPeriodLength = parameterLeiosAnnouncementPeriodLength current,
      updateLeiosVotePeriodLength = parameterLeiosVotePeriodLength current,
      updateLeiosDiffusionPeriodLength = parameterLeiosDiffusionPeriodLength current,
      updateLeiosCommitteeSize = parameterLeiosCommitteeSize current,
      updateLeiosQuorumStakeThreshold = parameterLeiosQuorumStakeThreshold current,
      updateMaxEndorserBlockReferencesSize = parameterMaxEndorserBlockReferencesSize current,
      updateMaxEndorserBlockTxsSize = parameterMaxEndorserBlockTxsSize current,
      updateMaxEndorserBlockExecutionUnits = parameterMaxEndorserBlockExecutionUnits current,
      updateMaxRefScriptSizePerEndorserBlock = parameterMaxRefScriptSizePerEndorserBlock current,
      updatePerasMinCandidateBlockAge = parameterPerasMinCandidateBlockAge current,
      updatePerasHealingFactor = parameterPerasHealingFactor current,
      updatePerasCertBoost = parameterPerasCertBoost current,
      updatePerasTargetCommitteeSize = parameterPerasTargetCommitteeSize current,
      updatePerasBootstrapRound = parameterPerasBootstrapRound current,
      updatePerasQuorumThresholdSafetyMargin = parameterPerasQuorumThresholdSafetyMargin current,
      updateRefInputsCostPerMultiAssetPolicy = parameterRefInputsCostPerMultiAssetPolicy current,
      updateRefInputsCostPerDatumByte = parameterRefInputsCostPerDatumByte current
    }

-- CBOR -----------------------------------------------------------------------

-- | Serialize present fields in ascending parameter-key order, using definite
-- collections and minimal integer encodings. Rational pairs remain exact;
-- imported representation is preserved only by 'toCbor'.
encodeCbor :: Update -> ByteString
encodeCbor change = Write.toStrictByteString (Encode.encodeMapLen (fromIntegral (length entries)) <> mconcat entries)
  where
    entries =
      concat
        [ field 0 Encode.encodeWord64 (updateMinFeeA change),
          field 1 Encode.encodeWord64 (updateMinFeeB change),
          field 2 Encode.encodeWord64 (updateMaxBlockBodySize change),
          field 3 Encode.encodeWord64 (updateMaxTxSize change),
          field 4 Encode.encodeWord64 (updateMaxBlockHeaderSize change),
          field 5 Encode.encodeWord64 (updateKeyDeposit change),
          field 6 Encode.encodeWord64 (updatePoolDeposit change),
          field 7 Encode.encodeWord64 (updateMaxEpoch change),
          field 8 Encode.encodeWord64 (updateDesiredPoolCount change),
          field 9 Values.encodeRational (updatePoolPledgeInfluence change),
          field 10 Values.encodeUnitInterval (updateExpansionRate change),
          field 11 Values.encodeUnitInterval (updateTreasuryGrowthRate change),
          field 12 Values.encodeUnitInterval (updateDecentralization change),
          field 13 encodeNonce (updateExtraEntropy change),
          field 14 Values.encodeProtocolVersion (updateProtocolVersion change),
          field 16 Encode.encodeWord64 (updateMinPoolCost change),
          field 17 Encode.encodeWord64 (updateAdaPerUtxoByte change),
          field 18 Models.encodeCostModels (updateCostModels change),
          field 19 Values.encodeExUnitPrices (updateExecutionCosts change),
          field 20 Values.encodeExUnits (updateMaxTxExUnits change),
          field 21 Values.encodeExUnits (updateMaxBlockExUnits change),
          field 22 Encode.encodeWord64 (updateMaxValueSize change),
          field 23 Encode.encodeWord64 (updateCollateralPercentage change),
          field 24 Encode.encodeWord64 (updateMaxCollateralInputs change),
          field 25 Values.encodePoolVotingThresholds (updatePoolVotingThresholds change),
          field 26 Values.encodeDRepVotingThresholds (updateDrepVotingThresholds change),
          field 27 Encode.encodeWord64 (updateMinCommitteeSize change),
          field 28 Encode.encodeWord64 (updateCommitteeTermLimit change),
          field 29 Encode.encodeWord64 (updateGovernanceActionValidityPeriod change),
          field 30 Encode.encodeWord64 (updateGovernanceActionDeposit change),
          field 31 Encode.encodeWord64 (updateDrepDeposit change),
          field 32 Encode.encodeWord64 (updateDrepInactivityPeriod change),
          field 33 Values.encodeRational (updateRefScriptCostPerByte change),
          field 34 Encode.encodeWord32 (updateMaxRefScriptSizePerBlock change),
          field 35 Encode.encodeWord32 (updateMaxRefScriptSizePerTx change),
          field 36 (Encode.encodeWord32 . Parameters.referenceScriptCostStride) (updateRefScriptCostStride change),
          field 37 Values.encodeRational (updateRefScriptCostMultiplier change),
          field 38 (encodeNullable Values.encodeRational) (updateMaxPledgeLeverage change),
          field 39 Values.encodeUnitInterval (updateMinPoolMargin change),
          field 40 Encode.encodeWord32 (updateLeiosAnnouncementPeriodLength change),
          field 41 Encode.encodeWord32 (updateLeiosVotePeriodLength change),
          field 42 Encode.encodeWord32 (updateLeiosDiffusionPeriodLength change),
          field 43 Encode.encodeWord16 (updateLeiosCommitteeSize change),
          field 44 Values.encodeUnitInterval (updateLeiosQuorumStakeThreshold change),
          field 45 Encode.encodeWord32 (updateMaxEndorserBlockReferencesSize change),
          field 46 Encode.encodeWord32 (updateMaxEndorserBlockTxsSize change),
          field 47 Values.encodeExUnits (updateMaxEndorserBlockExecutionUnits change),
          field 48 Encode.encodeWord32 (updateMaxRefScriptSizePerEndorserBlock change),
          field 49 Encode.encodeWord32 (updatePerasMinCandidateBlockAge change),
          field 50 Values.encodeRational (updatePerasHealingFactor change),
          field 51 Encode.encodeWord16 (updatePerasCertBoost change),
          field 52 Encode.encodeWord16 (updatePerasTargetCommitteeSize change),
          field 53 (encodeNullable Encode.encodeWord32) (updatePerasBootstrapRound change),
          field 54 Values.encodeUnitInterval (updatePerasQuorumThresholdSafetyMargin change),
          field 55 Encode.encodeWord64 (updateRefInputsCostPerMultiAssetPolicy change),
          field 56 Encode.encodeWord64 (updateRefInputsCostPerDatumByte change)
        ]

-- | Decode one complete update, retaining exact bytes. Unknown or duplicate
-- parameter keys, invalid field bounds/arity, malformed CBOR and trailing input
-- return 'InvalidProtocolParametersCbor'. Historical fields are accepted without
-- applying era-specific governance validity rules.
decodeCbor :: ByteString -> Either Error EncodedUpdate
decodeCbor bytes = case Read.deserialiseFromBytes decodeUpdate (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidProtocolParametersCbor (Text.pack (show failure)))
  Right (trailing, change)
    | Lazy.null trailing -> Right (EncodedUpdate bytes change)
    | otherwise -> Left (InvalidProtocolParametersCbor "Trailing bytes after protocol update")

-- | Return the exact validated input encoding.
toCbor :: EncodedUpdate -> ByteString
toCbor (EncodedUpdate bytes _) = bytes

-- | Inspect the Haskell-owned change without altering its original encoding.
toUpdate :: EncodedUpdate -> Update
toUpdate (EncodedUpdate _ change) = change

field :: Word64 -> (a -> Encode.Encoding) -> Maybe a -> [Encode.Encoding]
field key encode = maybe [] (\value -> [Encode.encodeWord64 key <> encode value])

encodeNullable :: (a -> Encode.Encoding) -> Maybe a -> Encode.Encoding
encodeNullable = maybe Encode.encodeNull

encodeNonce :: Nonce -> Encode.Encoding
encodeNonce nonce = case Parameters.nonceBytes nonce of
  Nothing -> Encode.encodeListLen 1 <> Encode.encodeWord 0
  Just bytes -> Encode.encodeListLen 2 <> Encode.encodeWord 1 <> Encode.encodeBytes bytes

decodeNullable :: Decode.Decoder s a -> Decode.Decoder s (Maybe a)
decodeNullable decode = do
  token <- Decode.peekTokenType
  if token == Decode.TypeNull then Decode.decodeNull >> pure Nothing else Just <$> decode

decodeNonce :: Decode.Decoder s Nonce
decodeNonce = do
  size <- Decode.decodeListLen
  tag <- Decode.decodeWord
  case (size, tag) of
    (1, 0) -> pure Parameters.neutralNonce
    (2, 1) -> do
      bytes <- Decode.decodeBytes
      either (const (fail "Nonce digest must contain 32 bytes")) pure (Parameters.mkNonce bytes)
    _ -> fail "Invalid entropy nonce variant or arity"

decodeStride :: Decode.Decoder s ReferenceScriptCostStride
decodeStride = do
  value <- Decode.decodeWord32
  either (const (fail "Reference script cost stride must be positive")) pure (Parameters.mkReferenceScriptCostStride (toInteger value))

decodeUpdate :: Decode.Decoder s Update
decodeUpdate = do
  count <- Decode.decodeMapLenOrIndef
  go count Set.empty empty
  where
    go (Just 0) _ change = pure change
    go count seen change = do
      ended <- case count of
        Nothing -> Decode.decodeBreakOr
        Just _ -> pure False
      if ended
        then pure change
        else do
          key <- Decode.decodeWord64
          unless (Set.notMember key seen) (fail "Duplicate protocol parameter key")
          next <- case key of
            0 -> (\value -> change {updateMinFeeA = Just value}) <$> Decode.decodeWord64
            1 -> (\value -> change {updateMinFeeB = Just value}) <$> Decode.decodeWord64
            2 -> (\value -> change {updateMaxBlockBodySize = Just value}) <$> Decode.decodeWord64
            3 -> (\value -> change {updateMaxTxSize = Just value}) <$> Decode.decodeWord64
            4 -> (\value -> change {updateMaxBlockHeaderSize = Just value}) <$> Decode.decodeWord64
            5 -> (\value -> change {updateKeyDeposit = Just value}) <$> Decode.decodeWord64
            6 -> (\value -> change {updatePoolDeposit = Just value}) <$> Decode.decodeWord64
            7 -> (\value -> change {updateMaxEpoch = Just value}) <$> Decode.decodeWord64
            8 -> (\value -> change {updateDesiredPoolCount = Just value}) <$> Decode.decodeWord64
            9 -> (\value -> change {updatePoolPledgeInfluence = Just value}) <$> Values.decodeRational
            10 -> (\value -> change {updateExpansionRate = Just value}) <$> Values.decodeUnitInterval
            11 -> (\value -> change {updateTreasuryGrowthRate = Just value}) <$> Values.decodeUnitInterval
            12 -> (\value -> change {updateDecentralization = Just value}) <$> Values.decodeUnitInterval
            13 -> (\value -> change {updateExtraEntropy = Just value}) <$> decodeNonce
            14 -> (\value -> change {updateProtocolVersion = Just value}) <$> Values.decodeProtocolVersion
            16 -> (\value -> change {updateMinPoolCost = Just value}) <$> Decode.decodeWord64
            17 -> (\value -> change {updateAdaPerUtxoByte = Just value}) <$> Decode.decodeWord64
            18 -> (\value -> change {updateCostModels = Just value}) <$> Models.decodeCostModels
            19 -> (\value -> change {updateExecutionCosts = Just value}) <$> Values.decodeExUnitPrices
            20 -> (\value -> change {updateMaxTxExUnits = Just value}) <$> Values.decodeExUnits
            21 -> (\value -> change {updateMaxBlockExUnits = Just value}) <$> Values.decodeExUnits
            22 -> (\value -> change {updateMaxValueSize = Just value}) <$> Decode.decodeWord64
            23 -> (\value -> change {updateCollateralPercentage = Just value}) <$> Decode.decodeWord64
            24 -> (\value -> change {updateMaxCollateralInputs = Just value}) <$> Decode.decodeWord64
            25 -> (\value -> change {updatePoolVotingThresholds = Just value}) <$> Values.decodePoolVotingThresholds
            26 -> (\value -> change {updateDrepVotingThresholds = Just value}) <$> Values.decodeDRepVotingThresholds
            27 -> (\value -> change {updateMinCommitteeSize = Just value}) <$> Decode.decodeWord64
            28 -> (\value -> change {updateCommitteeTermLimit = Just value}) <$> Decode.decodeWord64
            29 -> (\value -> change {updateGovernanceActionValidityPeriod = Just value}) <$> Decode.decodeWord64
            30 -> (\value -> change {updateGovernanceActionDeposit = Just value}) <$> Decode.decodeWord64
            31 -> (\value -> change {updateDrepDeposit = Just value}) <$> Decode.decodeWord64
            32 -> (\value -> change {updateDrepInactivityPeriod = Just value}) <$> Decode.decodeWord64
            33 -> (\value -> change {updateRefScriptCostPerByte = Just value}) <$> Values.decodeRational
            34 -> (\value -> change {updateMaxRefScriptSizePerBlock = Just value}) <$> Decode.decodeWord32
            35 -> (\value -> change {updateMaxRefScriptSizePerTx = Just value}) <$> Decode.decodeWord32
            36 -> (\value -> change {updateRefScriptCostStride = Just value}) <$> decodeStride
            37 -> (\value -> change {updateRefScriptCostMultiplier = Just value}) <$> Values.decodeRational
            38 -> (\value -> change {updateMaxPledgeLeverage = Just value}) <$> decodeNullable Values.decodeRational
            39 -> (\value -> change {updateMinPoolMargin = Just value}) <$> Values.decodeUnitInterval
            40 -> (\value -> change {updateLeiosAnnouncementPeriodLength = Just value}) <$> Decode.decodeWord32
            41 -> (\value -> change {updateLeiosVotePeriodLength = Just value}) <$> Decode.decodeWord32
            42 -> (\value -> change {updateLeiosDiffusionPeriodLength = Just value}) <$> Decode.decodeWord32
            43 -> (\value -> change {updateLeiosCommitteeSize = Just value}) <$> Decode.decodeWord16
            44 -> (\value -> change {updateLeiosQuorumStakeThreshold = Just value}) <$> Values.decodeUnitInterval
            45 -> (\value -> change {updateMaxEndorserBlockReferencesSize = Just value}) <$> Decode.decodeWord32
            46 -> (\value -> change {updateMaxEndorserBlockTxsSize = Just value}) <$> Decode.decodeWord32
            47 -> (\value -> change {updateMaxEndorserBlockExecutionUnits = Just value}) <$> Values.decodeExUnits
            48 -> (\value -> change {updateMaxRefScriptSizePerEndorserBlock = Just value}) <$> Decode.decodeWord32
            49 -> (\value -> change {updatePerasMinCandidateBlockAge = Just value}) <$> Decode.decodeWord32
            50 -> (\value -> change {updatePerasHealingFactor = Just value}) <$> Values.decodeRational
            51 -> (\value -> change {updatePerasCertBoost = Just value}) <$> Decode.decodeWord16
            52 -> (\value -> change {updatePerasTargetCommitteeSize = Just value}) <$> Decode.decodeWord16
            53 -> (\value -> change {updatePerasBootstrapRound = Just value}) <$> decodeNullable Decode.decodeWord32
            54 -> (\value -> change {updatePerasQuorumThresholdSafetyMargin = Just value}) <$> Values.decodeUnitInterval
            55 -> (\value -> change {updateRefInputsCostPerMultiAssetPolicy = Just value}) <$> Decode.decodeWord64
            56 -> (\value -> change {updateRefInputsCostPerDatumByte = Just value}) <$> Decode.decodeWord64
            _ -> fail "Unknown protocol parameter key"
          go (subtract 1 <$> count) (Set.insert key seen) next
