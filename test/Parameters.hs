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

-- | Complete typed snapshots, sparse changes and native semantic reconstruction.
module Parameters (tests) where

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import Cometa.Error (Error (..))
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Parameters.Update as U
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import Data.Word (Word64, Word8)
import qualified Fixtures.ProtocolParameters as Fixtures
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Protocol parameter updates"
    [ testCase "all 56 fields roundtrip through typed native full snapshot reconstruction" checkAll,
      testCase "Conway snapshots omit future and deprecated fields" checkAvailability,
      testCase "independent pinned update vector selects the expected semantic fields" checkGolden,
      testCase "nullable fields preserve absent null and value states" checkNullable,
      testCase "exact import bytes remain distinct from normalized serialization" checkIdentity,
      testCase "invalid schema bounds duplicates unknown and trailing bytes fail" checkInvalid,
      testCase "nonce and positive stride validation reject invalid boundaries" checkBounds,
      testProperty "sparse fee edits preserve other full fields and native semantics" propFees
    ]

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\failure -> assertFailure (show failure) >> fail "unreachable") pure

fixture :: IO P.Parameters
fixture = expectRight Fixtures.parameters

checkAll :: IO ()
checkAll = do
  full <- fixture
  let change = U.fromParameters full
      encoded = U.encodeCbor change
  decoded <- expectRight (U.decodeCbor encoded)
  U.toUpdate decoded @?= change
  U.apply U.empty full @?= full
  U.apply change full @?= full
  nativeAgreement encoded encoded
  -- Every individual field is exercised separately, verifying absence of the others.
  forM_ (zip ([0 .. 14] <> [16 .. 56] :: [Word64]) (individualChanges full)) $ \(expectedKey, item) -> do
    -- Independently pin the wire key for each named public field.
    case Read.deserialiseFromBytes (Decode.decodeMapLen >> Decode.decodeWord64) (Lazy.fromStrict (U.encodeCbor item)) of
      Left failure -> assertFailure (show failure)
      Right (_, actualKey) -> actualKey @?= expectedKey
    result <- expectRight (U.decodeCbor (U.encodeCbor item))
    U.toUpdate result @?= item
    nativeAgreement (U.encodeCbor item) (U.encodeCbor item)

individualChanges :: P.Parameters -> [U.Update]
individualChanges full =
  [ U.empty {U.updateMinFeeA = Just (P.parameterMinFeeA full)},
    U.empty {U.updateMinFeeB = Just (P.parameterMinFeeB full)},
    U.empty {U.updateMaxBlockBodySize = Just (P.parameterMaxBlockBodySize full)},
    U.empty {U.updateMaxTxSize = Just (P.parameterMaxTxSize full)},
    U.empty {U.updateMaxBlockHeaderSize = Just (P.parameterMaxBlockHeaderSize full)},
    U.empty {U.updateKeyDeposit = Just (P.parameterKeyDeposit full)},
    U.empty {U.updatePoolDeposit = Just (P.parameterPoolDeposit full)},
    U.empty {U.updateMaxEpoch = Just (P.parameterMaxEpoch full)},
    U.empty {U.updateDesiredPoolCount = Just (P.parameterDesiredPoolCount full)},
    U.empty {U.updatePoolPledgeInfluence = Just (P.parameterPoolPledgeInfluence full)},
    U.empty {U.updateExpansionRate = Just (P.parameterExpansionRate full)},
    U.empty {U.updateTreasuryGrowthRate = Just (P.parameterTreasuryGrowthRate full)},
    U.empty {U.updateDecentralization = P.parameterDecentralization full},
    U.empty {U.updateExtraEntropy = P.parameterExtraEntropy full},
    U.empty {U.updateProtocolVersion = Just (P.parameterProtocolVersion full)},
    U.empty {U.updateMinPoolCost = Just (P.parameterMinPoolCost full)},
    U.empty {U.updateAdaPerUtxoByte = P.parameterAdaPerUtxoByte full},
    U.empty {U.updateCostModels = P.parameterCostModels full},
    U.empty {U.updateExecutionCosts = P.parameterExecutionCosts full},
    U.empty {U.updateMaxTxExUnits = P.parameterMaxTxExUnits full},
    U.empty {U.updateMaxBlockExUnits = P.parameterMaxBlockExUnits full},
    U.empty {U.updateMaxValueSize = P.parameterMaxValueSize full},
    U.empty {U.updateCollateralPercentage = P.parameterCollateralPercentage full},
    U.empty {U.updateMaxCollateralInputs = P.parameterMaxCollateralInputs full},
    U.empty {U.updatePoolVotingThresholds = P.parameterPoolVotingThresholds full},
    U.empty {U.updateDrepVotingThresholds = P.parameterDrepVotingThresholds full},
    U.empty {U.updateMinCommitteeSize = P.parameterMinCommitteeSize full},
    U.empty {U.updateCommitteeTermLimit = P.parameterCommitteeTermLimit full},
    U.empty {U.updateGovernanceActionValidityPeriod = P.parameterGovernanceActionValidityPeriod full},
    U.empty {U.updateGovernanceActionDeposit = P.parameterGovernanceActionDeposit full},
    U.empty {U.updateDrepDeposit = P.parameterDrepDeposit full},
    U.empty {U.updateDrepInactivityPeriod = P.parameterDrepInactivityPeriod full},
    U.empty {U.updateRefScriptCostPerByte = P.parameterRefScriptCostPerByte full},
    U.empty {U.updateMaxRefScriptSizePerBlock = P.parameterMaxRefScriptSizePerBlock full},
    U.empty {U.updateMaxRefScriptSizePerTx = P.parameterMaxRefScriptSizePerTx full},
    U.empty {U.updateRefScriptCostStride = P.parameterRefScriptCostStride full},
    U.empty {U.updateRefScriptCostMultiplier = P.parameterRefScriptCostMultiplier full},
    U.empty {U.updateMaxPledgeLeverage = P.parameterMaxPledgeLeverage full},
    U.empty {U.updateMinPoolMargin = P.parameterMinPoolMargin full},
    U.empty {U.updateLeiosAnnouncementPeriodLength = P.parameterLeiosAnnouncementPeriodLength full},
    U.empty {U.updateLeiosVotePeriodLength = P.parameterLeiosVotePeriodLength full},
    U.empty {U.updateLeiosDiffusionPeriodLength = P.parameterLeiosDiffusionPeriodLength full},
    U.empty {U.updateLeiosCommitteeSize = P.parameterLeiosCommitteeSize full},
    U.empty {U.updateLeiosQuorumStakeThreshold = P.parameterLeiosQuorumStakeThreshold full},
    U.empty {U.updateMaxEndorserBlockReferencesSize = P.parameterMaxEndorserBlockReferencesSize full},
    U.empty {U.updateMaxEndorserBlockTxsSize = P.parameterMaxEndorserBlockTxsSize full},
    U.empty {U.updateMaxEndorserBlockExecutionUnits = P.parameterMaxEndorserBlockExecutionUnits full},
    U.empty {U.updateMaxRefScriptSizePerEndorserBlock = P.parameterMaxRefScriptSizePerEndorserBlock full},
    U.empty {U.updatePerasMinCandidateBlockAge = P.parameterPerasMinCandidateBlockAge full},
    U.empty {U.updatePerasHealingFactor = P.parameterPerasHealingFactor full},
    U.empty {U.updatePerasCertBoost = P.parameterPerasCertBoost full},
    U.empty {U.updatePerasTargetCommitteeSize = P.parameterPerasTargetCommitteeSize full},
    U.empty {U.updatePerasBootstrapRound = P.parameterPerasBootstrapRound full},
    U.empty {U.updatePerasQuorumThresholdSafetyMargin = P.parameterPerasQuorumThresholdSafetyMargin full},
    U.empty {U.updateRefInputsCostPerMultiAssetPolicy = P.parameterRefInputsCostPerMultiAssetPolicy full},
    U.empty {U.updateRefInputsCostPerDatumByte = P.parameterRefInputsCostPerDatumByte full}
  ]

checkGolden :: IO ()
checkGolden = do
  -- Native protocol_param_update.c map keys: min_fee_a=0, min_fee_b=1,
  -- max_ref_script_size_per_block=34, max_pledge_leverage=38.
  let bytes = BS.pack [0xa4, 0, 0x18, 44, 1, 0x1a, 0, 2, 0x5e, 0xf5, 0x18, 34, 0x19, 1, 0, 0x18, 38, 0xf6]
      expected = U.empty {U.updateMinFeeA = Just 44, U.updateMinFeeB = Just 155381, U.updateMaxRefScriptSizePerBlock = Just 256, U.updateMaxPledgeLeverage = Just Nothing}
  decoded <- expectRight (U.decodeCbor bytes)
  U.toUpdate decoded @?= expected
  U.encodeCbor expected @?= bytes
  nativeAgreement bytes bytes

checkAvailability :: IO ()
checkAvailability = do
  full <- fixture
  let conway =
        full
          { P.parameterDecentralization = Nothing,
            P.parameterExtraEntropy = Nothing,
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
      change = U.fromParameters conway
  U.apply U.empty conway @?= conway
  U.apply change conway @?= conway
  U.updateMaxRefScriptSizePerBlock change @?= Nothing
  U.updateMaxPledgeLeverage change @?= Nothing
  U.updateDecentralization change @?= Nothing
  let feeEdit = U.empty {U.updateMinFeeB = Just 42}
  U.apply feeEdit conway @?= conway {P.parameterMinFeeB = 42}
  nativeAgreement (U.encodeCbor change) (U.encodeCbor change)
  decoded <- expectRight (U.decodeCbor (U.encodeCbor change))
  U.toUpdate decoded @?= change

checkNullable :: IO ()
checkNullable = do
  full <- fixture
  let changes = [U.empty, U.empty {U.updateMaxPledgeLeverage = Just Nothing}, U.empty {U.updatePerasBootstrapRound = Just Nothing}, U.empty {U.updateMaxPledgeLeverage = P.parameterMaxPledgeLeverage full, U.updatePerasBootstrapRound = P.parameterPerasBootstrapRound full}]
  forM_ changes $ \change -> do
    result <- expectRight (U.decodeCbor (U.encodeCbor change))
    U.toUpdate result @?= change
    nativeAgreement (U.encodeCbor change) (U.encodeCbor change)
  let removed = U.apply (U.empty {U.updateMaxPledgeLeverage = Just Nothing, U.updatePerasBootstrapRound = Just Nothing}) full
  P.parameterMaxPledgeLeverage removed @?= Just Nothing
  P.parameterPerasBootstrapRound removed @?= Just Nothing
  -- Neutral entropy is separate from absent entropy.
  let neutral = U.empty {U.updateExtraEntropy = Just P.neutralNonce}
  nativeAgreement (U.encodeCbor neutral) (U.encodeCbor neutral)

checkIdentity :: IO ()
checkIdentity = do
  let original = BS.pack [0xbf, 0x18, 0, 0x18, 1, 0xff]
  decoded <- expectRight (U.decodeCbor original)
  U.toCbor decoded @?= original
  U.toUpdate decoded @?= U.empty {U.updateMinFeeA = Just 1}
  U.encodeCbor (U.toUpdate decoded) @?= BS.pack [0xa1, 0, 1]
  -- Native pinned update decoding supports only definite maps.
  nativeAgreement (U.encodeCbor (U.toUpdate decoded)) (U.encodeCbor (U.toUpdate decoded))
  let definiteNonminimal = BS.pack [0xa1, 0x18, 0, 0x18, 1]
  nativeAgreement definiteNonminimal (BS.pack [0xa1, 0, 1])

checkInvalid :: IO ()
checkInvalid = do
  let encode = Write.toStrictByteString
      uint key value = Encode.encodeMapLen 1 <> Encode.encodeWord key <> Encode.encodeInteger value
      malformed =
        map BS.pack [[0xa1, 15, 0], [0xa2, 0, 1, 0, 2], [0xa1, 0, 0x20], [0xa0, 0], [0x80], [0xa1, 13, 0x81, 1], [0xa1, 13, 0x82, 1, 0x40], [0xa1, 36, 0], [0xa1, 38, 0x80], [0xa1, 53, 0x20]]
          <> [encode (uint key 4294967296) | key <- [34, 35, 36, 40, 41, 42, 45, 46, 48, 49, 53]]
          <> [encode (uint key 65536) | key <- [43, 51, 52]]
  forM_ malformed $ \bytes -> assertBool "invalid update accepted" (isLeft (U.decodeCbor bytes))

checkBounds :: IO ()
checkBounds = do
  forM_ [-1, 0, 4294967296] $ \value -> P.mkReferenceScriptCostStride value @?= Left (InvalidReferenceScriptCostStride value)
  forM_ [1, 4294967295] $ \value -> do
    stride <- expectRight (P.mkReferenceScriptCostStride value)
    toInteger (P.referenceScriptCostStride stride) @?= value
  forM_ [0, 1, 31, 33] $ \count -> P.mkNonce (BS.replicate count 0) @?= Left (InvalidProtocolNonceLength count)
  P.nonceBytes P.neutralNonce @?= Nothing
  forM_ [U.empty {U.updateMinFeeA = Just maxBound}, U.empty {U.updateMaxValueSize = Just maxBound}, U.empty {U.updateMaxRefScriptSizePerBlock = Just maxBound}, U.empty {U.updateLeiosCommitteeSize = Just maxBound}] $ \change -> do
    decoded <- expectRight (U.decodeCbor (U.encodeCbor change))
    U.toUpdate decoded @?= change
    nativeAgreement (U.encodeCbor change) (U.encodeCbor change)

propFees :: Property
propFees = property $ do
  a <- forAll (Gen.word64 Range.constantBounded)
  b <- forAll (Gen.word64 Range.constantBounded)
  full <- evalIO fixture
  let change = U.empty {U.updateMinFeeA = Just a, U.updateMinFeeB = Just b}
      result = U.apply change full
  decoded <- evalEither (U.decodeCbor (U.encodeCbor change))
  U.toUpdate decoded === change
  result === full {P.parameterMinFeeA = a, P.parameterMinFeeB = b}
  evalIO (nativeAgreement (U.encodeCbor change) (U.encodeCbor change))

nativeAgreement :: BS.ByteString -> BS.ByteString -> IO ()
nativeAgreement input expected = BS.useAsCStringLen input $ \(inputPtr, inputSize) -> BS.useAsCStringLen expected $ \(expectedPtr, expectedSize) -> do
  result <- c_agreement (castPtr inputPtr) (fromIntegral inputSize) (castPtr expectedPtr) (fromIntegral expectedSize)
  result @?= 1

-- All storage is borrowed through synchronous return; C scopes all native owners.
foreign import ccall unsafe "cometa_test_parameters_agreement"
  c_agreement :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CInt
