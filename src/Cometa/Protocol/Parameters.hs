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

-- | Typed protocol parameter snapshots. Era-dependent fields record availability;
-- there is no network-independent default. Sizes and money use unsigned bounded
-- integers, exact rational values never use floating point. This representation
-- includes historical and Dijkstra fields; construction does not validate
-- activation or governance rules of a particular ledger era. Assemble changes with
-- "Cometa.Protocol.Parameters.Update".
--
-- @
-- import qualified Cometa.Protocol.Parameters as Parameters
-- import Data.Word (Word64)
--
-- feeTerms :: Parameters.Parameters -> (Word64, Word64)
-- feeTerms snapshot =
--   (Parameters.parameterMinFeeA snapshot, Parameters.parameterMinFeeB snapshot)
-- @
module Cometa.Protocol.Parameters
  ( Parameters (..),
    Nonce,
    neutralNonce,
    mkNonce,
    nonceBytes,
    ReferenceScriptCostStride,
    mkReferenceScriptCostStride,
    referenceScriptCostStride,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Internal.CostModels (CostModels)
import Cometa.Internal.ProtocolValues (DRepVotingThresholds, ExUnitPrices, ExUnits, NonNegativeRational, PoolVotingThresholds, ProtocolVersion, UnitInterval)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word16, Word32, Word64)

-- TYPES ----------------------------------------------------------------------

-- | A complete snapshot. Record updates preserve validated field invariants.
-- Optional era-dependent fields distinguish unavailable parameters from present
-- values. For nullable fields, Just Nothing means present but unbounded/unset.
data Parameters = Parameters
  { -- | Linear transaction fee coefficient in lovelace per byte.
    parameterMinFeeA :: !Word64,
    -- | Constant transaction fee in lovelace.
    parameterMinFeeB :: !Word64,
    -- | Maximum block body size in bytes.
    parameterMaxBlockBodySize :: !Word64,
    -- | Maximum transaction size in bytes.
    parameterMaxTxSize :: !Word64,
    -- | Maximum block header size in bytes.
    parameterMaxBlockHeaderSize :: !Word64,
    -- | Stake credential registration deposit in lovelace.
    parameterKeyDeposit :: !Word64,
    -- | Pool registration deposit in lovelace.
    parameterPoolDeposit :: !Word64,
    -- | Maximum pool retirement interval in epochs.
    parameterMaxEpoch :: !Word64,
    -- | Desired number of stake pools.
    parameterDesiredPoolCount :: !Word64,
    -- | Nonnegative pool pledge influence factor.
    parameterPoolPledgeInfluence :: !NonNegativeRational,
    -- | Monetary expansion fraction per epoch.
    parameterExpansionRate :: !UnitInterval,
    -- | Treasury growth fraction per epoch.
    parameterTreasuryGrowthRate :: !UnitInterval,
    -- | Decentralization fraction; deprecated after Alonzo.
    parameterDecentralization :: !(Maybe UnitInterval),
    -- | Extra entropy nonce; deprecated after Alonzo.
    parameterExtraEntropy :: !(Maybe Nonce),
    -- | Major and minor protocol version; updates deprecated after Babbage.
    parameterProtocolVersion :: !ProtocolVersion,
    -- | Minimum pool cost in lovelace per epoch.
    parameterMinPoolCost :: !Word64,
    -- | Minimum UTxO charge in lovelace per byte.
    parameterAdaPerUtxoByte :: !(Maybe Word64),
    -- | Language-indexed execution cost models.
    parameterCostModels :: !(Maybe CostModels),
    -- | Execution memory and step prices in lovelace per unit.
    parameterExecutionCosts :: !(Maybe ExUnitPrices),
    -- | Maximum execution units per transaction.
    parameterMaxTxExUnits :: !(Maybe ExUnits),
    -- | Maximum execution units per block.
    parameterMaxBlockExUnits :: !(Maybe ExUnits),
    -- | Maximum serialized value size in bytes.
    parameterMaxValueSize :: !(Maybe Word64),
    -- | Collateral as an integer percentage of script fees.
    parameterCollateralPercentage :: !(Maybe Word64),
    -- | Maximum number of collateral inputs.
    parameterMaxCollateralInputs :: !(Maybe Word64),
    -- | Stake pool governance voting thresholds.
    parameterPoolVotingThresholds :: !(Maybe PoolVotingThresholds),
    -- | DRep governance voting thresholds.
    parameterDrepVotingThresholds :: !(Maybe DRepVotingThresholds),
    -- | Minimum constitutional committee membership count.
    parameterMinCommitteeSize :: !(Maybe Word64),
    -- | Maximum committee term in epochs.
    parameterCommitteeTermLimit :: !(Maybe Word64),
    -- | Governance action lifetime in epochs.
    parameterGovernanceActionValidityPeriod :: !(Maybe Word64),
    -- | Governance action deposit in lovelace.
    parameterGovernanceActionDeposit :: !(Maybe Word64),
    -- | DRep registration deposit in lovelace.
    parameterDrepDeposit :: !(Maybe Word64),
    -- | DRep inactivity interval in epochs.
    parameterDrepInactivityPeriod :: !(Maybe Word64),
    -- | Base reference script charge in lovelace per byte.
    parameterRefScriptCostPerByte :: !(Maybe NonNegativeRational),
    -- | Maximum reference script size per block in bytes; Dijkstra.
    parameterMaxRefScriptSizePerBlock :: !(Maybe Word32),
    -- | Maximum reference script size per transaction in bytes; Dijkstra.
    parameterMaxRefScriptSizePerTx :: !(Maybe Word32),
    -- | Positive reference script tier stride in bytes; Dijkstra.
    parameterRefScriptCostStride :: !(Maybe ReferenceScriptCostStride),
    -- | Reference script tier multiplier; Dijkstra.
    parameterRefScriptCostMultiplier :: !(Maybe NonNegativeRational),
    -- | Maximum pledge leverage; @Just Nothing@ selects an unbounded value.
    parameterMaxPledgeLeverage :: !(Maybe (Maybe NonNegativeRational)),
    -- | Minimum stake pool profit margin fraction; Dijkstra.
    parameterMinPoolMargin :: !(Maybe UnitInterval),
    -- | Leios announcement period in milliseconds.
    parameterLeiosAnnouncementPeriodLength :: !(Maybe Word32),
    -- | Leios voting period in milliseconds.
    parameterLeiosVotePeriodLength :: !(Maybe Word32),
    -- | Leios diffusion period in milliseconds.
    parameterLeiosDiffusionPeriodLength :: !(Maybe Word32),
    -- | Leios committee member count.
    parameterLeiosCommitteeSize :: !(Maybe Word16),
    -- | Leios quorum fraction of stake.
    parameterLeiosQuorumStakeThreshold :: !(Maybe UnitInterval),
    -- | Maximum endorser block references size in bytes.
    parameterMaxEndorserBlockReferencesSize :: !(Maybe Word32),
    -- | Maximum endorser block transactions size in bytes.
    parameterMaxEndorserBlockTxsSize :: !(Maybe Word32),
    -- | Maximum execution units per endorser block.
    parameterMaxEndorserBlockExecutionUnits :: !(Maybe ExUnits),
    -- | Maximum reference script size per endorser block in bytes.
    parameterMaxRefScriptSizePerEndorserBlock :: !(Maybe Word32),
    -- | Minimum Peras candidate block age in slots.
    parameterPerasMinCandidateBlockAge :: !(Maybe Word32),
    -- | Peras healing factor.
    parameterPerasHealingFactor :: !(Maybe NonNegativeRational),
    -- | Peras certificate boost.
    parameterPerasCertBoost :: !(Maybe Word16),
    -- | Target Peras committee member count.
    parameterPerasTargetCommitteeSize :: !(Maybe Word16),
    -- | Manual Peras bootstrap round; @Just Nothing@ selects no round.
    parameterPerasBootstrapRound :: !(Maybe (Maybe Word32)),
    -- | Peras quorum safety margin fraction.
    parameterPerasQuorumThresholdSafetyMargin :: !(Maybe UnitInterval),
    -- | Reference input charge in lovelace per multi-asset policy.
    parameterRefInputsCostPerMultiAssetPolicy :: !(Maybe Word64),
    -- | Reference input charge in lovelace per datum byte.
    parameterRefInputsCostPerDatumByte :: !(Maybe Word64)
  }
  deriving (Eq, Show)

-- | A neutral entropy contribution or a 32-byte nonce digest.
-- Equality compares the neutral alternative or exact digest bytes.
newtype Nonce = Nonce ByteString deriving (Eq, Ord, Show)

-- | The neutral nonce, encoded as @[0]@ in a parameter update.
neutralNonce :: Nonce
neutralNonce = Nonce ByteString.empty

-- | Validate a nonce digest of exactly 32 bytes. Wrong lengths return
-- 'InvalidProtocolNonceLength'; use 'neutralNonce' for neutral entropy.
mkNonce :: ByteString -> Either Error Nonce
mkNonce bytes
  | ByteString.length bytes == 32 = Right (Nonce bytes)
  | otherwise = Left (InvalidProtocolNonceLength (ByteString.length bytes))

-- | Inspect the digest; 'Nothing' denotes the neutral nonce.
nonceBytes :: Nonce -> Maybe ByteString
nonceBytes (Nonce bytes)
  | ByteString.null bytes = Nothing
  | otherwise = Just bytes

-- | A positive 32-bit reference script tier stride, measured in bytes.
newtype ReferenceScriptCostStride = ReferenceScriptCostStride Word32 deriving (Eq, Ord, Show)

-- | Validate a byte stride in @1..4294967295@ inclusive. Invalid inputs return
-- 'InvalidReferenceScriptCostStride'.
mkReferenceScriptCostStride :: Integer -> Either Error ReferenceScriptCostStride
mkReferenceScriptCostStride value
  | value >= 1 && value <= 4294967295 = Right (ReferenceScriptCostStride (fromInteger value))
  | otherwise = Left (InvalidReferenceScriptCostStride value)

-- | Inspect the positive byte stride.
referenceScriptCostStride :: ReferenceScriptCostStride -> Word32
referenceScriptCostStride (ReferenceScriptCostStride value) = value
