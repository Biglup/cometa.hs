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

module BlockfrostProtocol (tests) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.DRepVotingThresholds (DRepVotingThresholds (..))
import Cometa.Protocol.ExUnitPrices (ExUnitPrices (..))
import qualified Cometa.Protocol.ExUnits as Units
import qualified Cometa.Protocol.Parameters as P
import Cometa.Protocol.PoolVotingThresholds (PoolVotingThresholds (..))
import qualified Cometa.Protocol.Rational as Fraction
import qualified Cometa.Protocol.Version as Version
import Cometa.Provider.Blockfrost.Internal.Protocol (decodeProtocolParameters)
import qualified Cometa.UnitInterval as Interval
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Ratio ((%))
import Data.Scientific (scientific)
import qualified Data.Text as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Blockfrost protocol snapshots"
    [ testCase "exact prices and unbounded pledge influence" exactPrices,
      testCase "all required base snapshot fields map independently" baseMapping,
      testCase "all Conway groups retain distinct positions and units" conwayMapping,
      testCase "nonce absence, neutral and hash remain distinct" nonceVariants,
      testCase "cost coefficients and monetary integer boundaries" boundaries,
      testCase "partial Conway groups and invalid domains fail" conwayFailures,
      testCase "preserve availability and neutral nonce" availability,
      testCase "Alonzo word charge is not a byte charge" alonzoUnits,
      testCase "cost models preserve ordered signed coefficients" models,
      testCase "reject partial execution-price group" $
        rejected (replace "price_mem" (Number 1) fixture),
      testCase "reject overflowing monetary value" $
        rejected (replace "key_deposit" (String "18446744073709551616") fixture),
      testCase "reject negative unsigned parameter" $
        rejected (replace "min_fee_a" (Number (-1)) fixture),
      testCase "reject fractional integer parameter" $
        rejected (replace "min_fee_a" (Number 0.5) fixture),
      testCase "reject pathological numeric exponent before expansion" $
        rejected (replace "a0" (Number (scientific 1 1000000)) fixture),
      testCase "reject minimum Int exponent without overflow" $
        rejected (replace "a0" (Number (scientific 1 minBound)) fixture),
      testCase "reject incomplete voting thresholds" $
        rejected (replace "pvt_motion_no_confidence" (Number 0.5) fixture),
      testCase "reject unknown language rather than discard its model" $
        rejected (replace "cost_models_raw" (object ["PlutusV99" .= ([1] :: [Int])]) fixture)
    ]

fixture :: Value
fixture =
  object
    [ "min_fee_a" .= (44 :: Int),
      "min_fee_b" .= (155381 :: Int),
      "max_block_size" .= (90112 :: Int),
      "max_tx_size" .= (16384 :: Int),
      "max_block_header_size" .= (1100 :: Int),
      "key_deposit" .= String "2000000",
      "pool_deposit" .= String "500000000",
      "e_max" .= (18 :: Int),
      "n_opt" .= (500 :: Int),
      "a0" .= Number 2.5,
      "rho" .= Number 0.003,
      "tau" .= Number 0.2,
      "protocol_major_ver" .= (10 :: Int),
      "protocol_minor_ver" .= (0 :: Int),
      "min_pool_cost" .= String "170000000",
      "coins_per_utxo_size" .= String "4310",
      "extra_entropy" .= Null
    ]

replace :: Key -> Value -> Value -> Value
replace key value (Object fields) = Object (KeyMap.insert key value fields)
replace _ _ value = value

rejected :: Value -> IO ()
rejected value = decodeProtocolParameters value @?= Left (InvalidProviderResponse "provider.protocolParameters")

parsed :: Value -> (P.Parameters -> IO ()) -> IO ()
parsed value action = either (assertFailure . show) action (decodeProtocolParameters value)

exactPrices :: IO ()
exactPrices = parsed snapshot $ \parameters -> do
  Fraction.toRational (P.parameterPoolPledgeInfluence parameters) @?= 5 % 2
  Interval.toRational (P.parameterExpansionRate parameters) @?= 3 % 1000
  case P.parameterExecutionCosts parameters of
    Nothing -> assertFailure "Missing execution prices"
    Just prices -> do
      Fraction.toRational (memoryPrice prices) @?= 577 % 10000
      Fraction.toRational (stepPrice prices) @?= 721 % 10000000
  where
    snapshot = replace "price_mem" (Number 0.0577) (replace "price_step" (Number 0.0000721) fixture)

availability :: IO ()
availability = parsed fixture $ \parameters -> do
  P.parameterCostModels parameters @?= Nothing
  P.parameterExtraEntropy parameters @?= Just P.neutralNonce
  P.parameterAdaPerUtxoByte parameters @?= Just 4310
  P.parameterMaxRefScriptSizePerTx parameters @?= Nothing
  P.parameterMaxPledgeLeverage parameters @?= Nothing

alonzoUnits :: IO ()
alonzoUnits = parsed (replace "protocol_major_ver" (Number 5) fixture) $ \parameters ->
  P.parameterAdaPerUtxoByte parameters @?= Nothing

models :: IO ()
models = parsed snapshot $ \parameters ->
  fmap (map Models.costs . Models.toList) (P.parameterCostModels parameters) @?= Just [[-1, 2, 3], [7, 8]]
  where
    snapshot = replace "cost_models_raw" (object ["PlutusV1" .= ([-1, 2, 3] :: [Int]), "PlutusV3" .= ([7, 8] :: [Int])]) fixture

remove :: Key -> Value -> Value
remove key (Object fields) = Object (KeyMap.delete key fields)
remove _ value = value

baseMapping :: IO ()
baseMapping = parsed fixture $ \parameters -> do
  P.parameterMinFeeA parameters @?= 44
  P.parameterMinFeeB parameters @?= 155381
  P.parameterMaxBlockBodySize parameters @?= 90112
  P.parameterMaxTxSize parameters @?= 16384
  P.parameterMaxBlockHeaderSize parameters @?= 1100
  P.parameterKeyDeposit parameters @?= 2000000
  P.parameterPoolDeposit parameters @?= 500000000
  P.parameterMaxEpoch parameters @?= 18
  P.parameterDesiredPoolCount parameters @?= 500
  P.parameterProtocolVersion parameters @?= Version.ProtocolVersion 10 0
  P.parameterMinPoolCost parameters @?= 170000000
  P.parameterDecentralization parameters @?= Nothing

poolKeys :: [Key]
poolKeys = ["pvt_motion_no_confidence", "pvt_committee_normal", "pvt_committee_no_confidence", "pvt_hard_fork_initiation", "pvt_p_p_security_group"]

drepKeys :: [Key]
drepKeys = ["dvt_motion_no_confidence", "dvt_committee_normal", "dvt_committee_no_confidence", "dvt_update_to_constitution", "dvt_hard_fork_initiation", "dvt_p_p_network_group", "dvt_p_p_economic_group", "dvt_p_p_technical_group", "dvt_p_p_gov_group", "dvt_treasury_withdrawal"]

conway :: Value
conway =
  foldr (uncurry replace) fixture $
    zip poolKeys [Number (scientific n (-2)) | n <- [1 .. 5]]
      ++ zip drepKeys [Number (scientific n (-2)) | n <- [11 .. 20]]
      ++ [ ("max_tx_ex_mem", String "123"),
           ("max_tx_ex_steps", String "456"),
           ("max_block_ex_mem", String "789"),
           ("max_block_ex_steps", String "101112"),
           ("max_val_size", Number 5000),
           ("collateral_percent", Number 150),
           ("max_collateral_inputs", Number 3),
           ("committee_min_size", Number 7),
           ("committee_max_term_length", Number 19),
           ("gov_action_lifetime", Number 23),
           ("gov_action_deposit", String "100000007"),
           ("drep_deposit", String "500000011"),
           ("drep_activity", Number 31),
           ("min_fee_ref_script_cost_per_byte", Number 1.5),
           ("decentralisation_param", Number 0.25)
         ]

conwayMapping :: IO ()
conwayMapping = parsed conway $ \parameters -> do
  let pool = fmap (\(PoolVotingThresholds a b c d e) -> map Interval.toRational [a, b, c, d, e]) (P.parameterPoolVotingThresholds parameters)
      drep = fmap (\(DRepVotingThresholds a b c d e f g h i j) -> map Interval.toRational [a, b, c, d, e, f, g, h, i, j]) (P.parameterDrepVotingThresholds parameters)
  pool @?= Just [n % 100 | n <- [1 .. 5]]
  drep @?= Just [n % 100 | n <- [11 .. 20]]
  P.parameterMaxTxExUnits parameters @?= Just (Units.ExUnits 123 456)
  P.parameterMaxBlockExUnits parameters @?= Just (Units.ExUnits 789 101112)
  P.parameterMaxValueSize parameters @?= Just 5000
  P.parameterCollateralPercentage parameters @?= Just 150
  P.parameterMaxCollateralInputs parameters @?= Just 3
  P.parameterMinCommitteeSize parameters @?= Just 7
  P.parameterCommitteeTermLimit parameters @?= Just 19
  P.parameterGovernanceActionValidityPeriod parameters @?= Just 23
  P.parameterGovernanceActionDeposit parameters @?= Just 100000007
  P.parameterDrepDeposit parameters @?= Just 500000011
  P.parameterDrepInactivityPeriod parameters @?= Just 31
  fmap Fraction.toRational (P.parameterRefScriptCostPerByte parameters) @?= Just (3 % 2)
  fmap Interval.toRational (P.parameterDecentralization parameters) @?= Just (1 % 4)

nonceVariants :: IO ()
nonceVariants = do
  parsed (remove "extra_entropy" fixture) $ \parameters -> P.parameterExtraEntropy parameters @?= Nothing
  parsed fixture $ \parameters -> P.parameterExtraEntropy parameters @?= Just P.neutralNonce
  hashed <- either (\failure -> assertFailure (show failure) >> fail "invalid nonce fixture") pure (P.mkNonce (B.replicate 32 0xab))
  parsed (replace "extra_entropy" (String (Text.replicate 32 "AB")) fixture) $ \parameters ->
    P.parameterExtraEntropy parameters @?= Just hashed
  parsed (foldr (`replace` Null) fixture (poolKeys ++ drepKeys ++ ["cost_models_raw", "price_mem", "price_step", "max_tx_ex_mem", "max_tx_ex_steps", "max_block_ex_mem", "max_block_ex_steps"])) $ \parameters -> do
    P.parameterPoolVotingThresholds parameters @?= Nothing
    P.parameterDrepVotingThresholds parameters @?= Nothing
    P.parameterCostModels parameters @?= Nothing
    P.parameterExecutionCosts parameters @?= Nothing
    P.parameterMaxTxExUnits parameters @?= Nothing
    P.parameterMaxBlockExUnits parameters @?= Nothing

boundaries :: IO ()
boundaries = do
  let signed = [minBound, maxBound] :: [Int64]
      boundaryModels = object [key .= signed | key <- ["PlutusV1", "PlutusV2", "PlutusV3", "PlutusV4"]]
  parsed (replace "cost_models_raw" boundaryModels fixture) $ \parameters ->
    fmap (map Models.costs . Models.toList) (P.parameterCostModels parameters) @?= Just (replicate 4 signed)
  parsed (replace "key_deposit" (String "18446744073709551615") fixture) $ \parameters ->
    P.parameterKeyDeposit parameters @?= maxBound
  forM_ [Number 0.5, String "9223372036854775808", String "-9223372036854775809"] $ \cost ->
    rejected (replace "cost_models_raw" (object ["PlutusV1" .= [cost]]) fixture)
  rejected (replace "cost_models_raw" (object ["PlutusV1" .= replicate 2049 (0 :: Int)]) fixture)
  parsed (replace "cost_models_raw" (object ["PlutusV1" .= replicate 2048 (0 :: Int)]) fixture) $ \parameters ->
    fmap (map (length . Models.costs) . Models.toList) (P.parameterCostModels parameters) @?= Just [2048]

conwayFailures :: IO ()
conwayFailures = do
  forM_ (poolKeys ++ drepKeys ++ ["max_tx_ex_mem", "max_tx_ex_steps", "max_block_ex_mem", "max_block_ex_steps"]) $ \key ->
    rejected (replace key Null conway)
  forM_ [("pvt_committee_normal", Number 1.01), ("dvt_committee_normal", Number (-0.01)), ("min_fee_ref_script_cost_per_byte", Number (-1)), ("drep_deposit", String "18446744073709551616"), ("extra_entropy", String "zz"), ("max_tx_ex_mem", Number 0.5)] $ \(key, value) ->
    rejected (replace key value conway)
