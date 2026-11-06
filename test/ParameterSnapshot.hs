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
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production full snapshot conversion, actual native getters and presence.
module ParameterSnapshot (tests) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.FFI.Native (NativeCode)
import Cometa.Internal.FFI.Runtime (Buffer)
import qualified Cometa.Internal.ParameterSnapshot as Snapshot
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Parameters.Update as Update
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.Word (Word8)
import qualified Fixtures.ProtocolParameters as Fixture
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Parameter snapshots"
    [ testCase "all 56 fields reconstruct through production full setters/getters" checkAll,
      testCase "native mutation is observed instead of echoing template" checkMutation,
      testCase "known-origin availability and nullable states survive native conversion" checkPresence,
      testCase "native-origin snapshot uses actual stored scalar values" checkNativeOrigin,
      testCase "native-origin older snapshot omits unset positive stride" checkHistorical,
      testCase "missing required fields and signed full-setter overflow fail" checkInvalid,
      testCase "repeated native reconstruction releases all owners" checkRepeated,
      testProperty "full snapshot scalar edits reconstruct without defaulting" propSnapshot
    ]

must :: (Show e) => Either e a -> IO a
must value = case value of
  Left failure -> assertFailure (show failure) >> fail "Invalid fixture"
  Right result -> pure result

roundtrip :: CUInt -> ByteString -> IO (Either Error ByteString)
roundtrip mode bytes = Runtime.withBytes bytes $ \input size -> Runtime.withOwnedBuffer "test.parameterSnapshot" (cSnapshot input size mode)

checkAll :: IO ()
checkAll = do
  parameters <- must Fixture.parameters
  let bytes = Snapshot.encodeSnapshot parameters
  reloaded <- roundtrip 0 bytes >>= must
  Snapshot.decodeSnapshot reloaded @?= Right parameters
  assertBool "fresh output is decoded schema, not assumed bytes" (not (B.null reloaded))

checkMutation :: IO ()
checkMutation = do
  parameters <- must Fixture.parameters
  reloaded <- roundtrip 1 (Snapshot.encodeSnapshot parameters) >>= must >>= must . Snapshot.decodeSnapshot
  reloaded @?= parameters {Parameters.parameterMinFeeA = Parameters.parameterMinFeeA parameters + 1}

checkPresence :: IO ()
checkPresence = do
  full <- must Fixture.parameters
  let absent = full {Parameters.parameterAdaPerUtxoByte = Nothing, Parameters.parameterDecentralization = Nothing, Parameters.parameterExtraEntropy = Nothing, Parameters.parameterMaxPledgeLeverage = Nothing, Parameters.parameterPerasBootstrapRound = Nothing, Parameters.parameterRefInputsCostPerDatumByte = Nothing, Parameters.parameterRefScriptCostStride = Nothing}
      unbounded = full {Parameters.parameterMaxPledgeLeverage = Just Nothing, Parameters.parameterPerasBootstrapRound = Just Nothing, Parameters.parameterExtraEntropy = Just Parameters.neutralNonce}
  forM_ [absent, unbounded] $ \parameters -> do
    reloaded <- roundtrip 0 (Snapshot.encodeSnapshot parameters) >>= must
    Snapshot.decodeSnapshot reloaded @?= Right parameters

checkNativeOrigin :: IO ()
checkNativeOrigin = do
  full <- must Fixture.parameters
  let source = full {Parameters.parameterAdaPerUtxoByte = Nothing, Parameters.parameterRefInputsCostPerDatumByte = Nothing, Parameters.parameterMaxPledgeLeverage = Nothing, Parameters.parameterPerasBootstrapRound = Nothing}
  snapshot <- roundtrip 2 (Snapshot.encodeSnapshot source) >>= must >>= must . Snapshot.decodeSnapshot
  Parameters.parameterAdaPerUtxoByte snapshot @?= Just 0
  Parameters.parameterRefInputsCostPerDatumByte snapshot @?= Just 0
  Parameters.parameterMaxPledgeLeverage snapshot @?= Just Nothing
  Parameters.parameterPerasBootstrapRound snapshot @?= Just Nothing
  Parameters.parameterMinFeeA snapshot @?= Parameters.parameterMinFeeA full

checkHistorical :: IO ()
checkHistorical = do
  full <- must Fixture.parameters
  let historical = full {Parameters.parameterDecentralization = Nothing, Parameters.parameterExtraEntropy = Nothing, Parameters.parameterAdaPerUtxoByte = Nothing, Parameters.parameterCostModels = Nothing, Parameters.parameterExecutionCosts = Nothing, Parameters.parameterMaxTxExUnits = Nothing, Parameters.parameterMaxBlockExUnits = Nothing, Parameters.parameterMaxValueSize = Nothing, Parameters.parameterCollateralPercentage = Nothing, Parameters.parameterMaxCollateralInputs = Nothing, Parameters.parameterPoolVotingThresholds = Nothing, Parameters.parameterDrepVotingThresholds = Nothing, Parameters.parameterMinCommitteeSize = Nothing, Parameters.parameterCommitteeTermLimit = Nothing, Parameters.parameterGovernanceActionValidityPeriod = Nothing, Parameters.parameterGovernanceActionDeposit = Nothing, Parameters.parameterDrepDeposit = Nothing, Parameters.parameterDrepInactivityPeriod = Nothing, Parameters.parameterRefScriptCostPerByte = Nothing, Parameters.parameterMaxRefScriptSizePerBlock = Nothing, Parameters.parameterMaxRefScriptSizePerTx = Nothing, Parameters.parameterRefScriptCostStride = Nothing, Parameters.parameterRefScriptCostMultiplier = Nothing, Parameters.parameterMaxPledgeLeverage = Nothing, Parameters.parameterMinPoolMargin = Nothing, Parameters.parameterLeiosAnnouncementPeriodLength = Nothing, Parameters.parameterLeiosVotePeriodLength = Nothing, Parameters.parameterLeiosDiffusionPeriodLength = Nothing, Parameters.parameterLeiosCommitteeSize = Nothing, Parameters.parameterLeiosQuorumStakeThreshold = Nothing, Parameters.parameterMaxEndorserBlockReferencesSize = Nothing, Parameters.parameterMaxEndorserBlockTxsSize = Nothing, Parameters.parameterMaxEndorserBlockExecutionUnits = Nothing, Parameters.parameterMaxRefScriptSizePerEndorserBlock = Nothing, Parameters.parameterPerasMinCandidateBlockAge = Nothing, Parameters.parameterPerasHealingFactor = Nothing, Parameters.parameterPerasCertBoost = Nothing, Parameters.parameterPerasTargetCommitteeSize = Nothing, Parameters.parameterPerasBootstrapRound = Nothing, Parameters.parameterPerasQuorumThresholdSafetyMargin = Nothing, Parameters.parameterRefInputsCostPerMultiAssetPolicy = Nothing, Parameters.parameterRefInputsCostPerDatumByte = Nothing}
  encoded <- roundtrip 2 (Snapshot.encodeSnapshot historical) >>= must
  decoded <- must (Snapshot.decodeSnapshot encoded)
  Parameters.parameterRefScriptCostStride decoded @?= Nothing
  Parameters.parameterAdaPerUtxoByte decoded @?= Just 0
  Parameters.parameterPoolPledgeInfluence decoded @?= Parameters.parameterPoolPledgeInfluence historical

checkInvalid :: IO ()
checkInvalid = do
  full <- must Fixture.parameters
  let sparse = Update.fromParameters full
      missing = [sparse {Update.updateMinFeeA = Nothing}, sparse {Update.updateMaxTxSize = Nothing}, sparse {Update.updatePoolPledgeInfluence = Nothing}, sparse {Update.updateProtocolVersion = Nothing}]
  forM_ missing $ \change -> do
    let bytes = Update.encodeCbor change
    assertBool "required field missing" (isLeft (Snapshot.decodeSnapshot bytes))
    result <- roundtrip 0 bytes
    assertBool "native conversion rejects rather than inventing required field" (isLeft result)
  let overflow = full {Parameters.parameterMaxValueSize = Just (fromIntegral (maxBound :: Int64) + 1)}
  assertBool "signed setter prevalidation" (isLeft (Snapshot.validateNative overflow))
  result <- roundtrip 0 (Snapshot.encodeSnapshot overflow)
  assertBool "native signed setter overflow rejected" (isLeft result)
  malformed <- roundtrip 0 (Snapshot.encodeSnapshot full <> B.singleton 0)
  assertBool "trailing bytes rejected" (isLeft malformed)

checkRepeated :: IO ()
checkRepeated = do
  full <- must Fixture.parameters
  replicateM_ 64 (roundtrip 0 (Snapshot.encodeSnapshot full) >>= must)

propSnapshot :: Property
propSnapshot = property $ do
  fee <- forAll (Gen.word64 Range.constantBounded)
  base <- evalEither Fixture.parameters
  let parameters = base {Parameters.parameterMinFeeB = fee}
  bytes <- evalIO (roundtrip 0 (Snapshot.encodeSnapshot parameters)) >>= evalEither
  result <- evalEither (Snapshot.decodeSnapshot bytes)
  result === parameters

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_parameter_snapshot"
  cSnapshot :: Ptr Word8 -> CSize -> CUInt -> Ptr (Ptr Buffer) -> IO NativeCode
