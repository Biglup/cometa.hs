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
{-# LANGUAGE ScopedTypeVariables #-}

-- | Offline native deferred-argument registration, resolution and lifetime tests.
module DeferredRedeemer (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionPlan as InternalPlan
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Exception (SomeException, displayException, throw, try)
import Control.Monad (replicateM_)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (elemIndex, isInfixOf, sort)
import qualified Fixtures.ProtocolParameters as Fixture
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Deferred redeemers"
    [ testCase "canonical spending index and selected snapshots survive repeated balances" spending,
      testCase "native VM accepts the resolved late mint argument" nativeMinting,
      testCase "one policy group mints several assets with one redeemer" minting,
      testCase "withdrawal and certificate callbacks share one balanced draft" otherPurposes,
      testCase "empty and net-zero mint groups never evaluate their callbacks" emptyMint,
      testCase "duplicate and mixed registrations fail before callbacks" conflicts,
      testCase "typed failures and lazy exceptions preserve identity and cleanup" failures,
      testCase "cancellation of a pure callback restores registration baseline" cancellation,
      testCase "deferred plans obey observational monoid laws" laws
    ]

must :: (Show e) => Either e a -> IO a
must = either (\e -> assertFailure (show e) >> fail "fixture") pure

fixture :: IO (Builder.Config, Output.Output, Utxo.Utxo)
fixture = do
  raw <- must Fixture.parameters
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  previous <- must (Id.fromBytes (B.replicate 32 8))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
      params =
        raw
          { P.parameterMinFeeA = 0,
            P.parameterMinFeeB = 0,
            P.parameterMaxTxSize = 16384,
            P.parameterMaxValueSize = Just 5000,
            P.parameterAdaPerUtxoByte = Just 4310,
            P.parameterProtocolVersion = Version.ProtocolVersion 10 0,
            P.parameterCollateralPercentage = Just 150,
            P.parameterMaxCollateralInputs = Just 3,
            P.parameterKeyDeposit = 2000000,
            P.parameterMaxTxExUnits = Just (ExUnits 10000000 10000000000)
          }
  funding <- must (Output.mkOutput destination (Value.lovelace 10000000) Datum.NoDatum Nothing)
  output <- must (Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing)
  let utxo = Utxo.utxo (Input.input previous 0) funding
      config =
        (Builder.defaultConfig params Slot.preview destination)
          { Builder.availableUtxos = [utxo],
            Builder.minimumFee = 200000
          }
  pure (config, output, utxo)

scriptFixture :: IO (Builder.Config, Output.Output, Utxo.Utxo, Script.Script)
scriptFixture = do
  (config, output, wallet) <- fixture
  script <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V2 (B.pack [1, 2, 3]))
  model <- must (Models.mkCostModel 1 (replicate 175 0))
  hash <- Script.hash script >>= must
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.ScriptCredential hash))
      datum = Data.fromData (Data.Integer 42)
  locked <- must (Output.mkOutput destination (Value.lovelace 10000000) (Datum.InlineDatum datum) Nothing)
  collateralId <- must (Id.fromBytes (B.replicate 32 10))
  collateralOutput <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 5000000) Datum.NoDatum Nothing)
  let evaluator = Evaluation.Evaluator $ \_ tx _ ->
        pure
          ( Evaluation.mkBudgets
              [(Evaluation.RedeemerId (Redeemer.purpose r) (Redeemer.index r), ExUnits 100 200) | r <- redeemers tx]
          )
      configured =
        config
          { Builder.availableUtxos = [],
            Builder.collateralUtxos = [Utxo.utxo (Input.input collateralId 0) collateralOutput],
            Builder.evaluator = Just evaluator,
            Builder.parameters = (Builder.parameters config) {P.parameterCostModels = Just (Models.fromList [model])}
          }
  pure (configured, output, Utxo.utxo (Utxo.input wallet) locked, script)

redeemers :: Tx.Transaction -> [Redeemer.Redeemer]
redeemers = Witnesses.redeemers . Witnesses.toWitnesses . Tx.witnesses

spending :: IO ()
spending = do
  baseline <- Runtime.liveContexts
  (config, output, input, script) <- scriptFixture
  precedingId <- must (Id.fromBytes (B.replicate 32 1))
  precedingOutput <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 3000000) Datum.NoDatum Nothing)
  let preceding = Utxo.utxo (Input.input precedingId 0) precedingOutput
      callback tx inputs = do
        let canonical = Fields.fieldInputs (Body.bodyFields (Body.toBody (Tx.body tx)))
        if map Utxo.input inputs /= sort canonical
          then Left (InvalidTransactionPlan "Deferred inputs are not selected canonical snapshots")
          else case elemIndex (Utxo.input input) canonical of
            Nothing -> Left (InvalidTransactionPlan "Required spending input disappeared")
            Just index -> Right (Data.fromData (Data.Constr 0 [Data.Integer (toInteger index)]))
      plan = Plan.spendWithDeferredRedeemer input callback Nothing <> Plan.spend preceding <> Plan.attachScript script <> Plan.payTo output
  replicateM_ 3 $ do
    tx <- Builder.build config plan >>= must
    let expected = case elemIndex (Utxo.input input) (Fields.fieldInputs (Body.bodyFields (Body.toBody (Tx.body tx)))) of
          Nothing -> Nothing
          Just index -> Just (Data.fromData (Data.Constr 0 [Data.Integer (toInteger index)]))
    map Redeemer.index (redeemers tx) @?= [1]
    map (Just . Redeemer.argument) (redeemers tx) @?= [expected]
  Runtime.liveContexts >>= (@?= baseline)

minting :: IO ()
minting = do
  (config, output, locked, script) <- scriptFixture
  funding <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 10000000) Datum.NoDatum Nothing)
  let input = Utxo.utxo (Utxo.input locked) funding
  hash <- Script.hash script >>= must
  policy <- must (Policy.fromBytes (Credential.scriptHashBytes hash))
  second <- must (AssetName.fromBytes (B.singleton 1))
  calls <- newIORef (0 :: Int)
  let argument = Data.fromData (Data.Integer 123)
      checked = Evaluation.Evaluator $ \_ tx _ -> do
        modifyIORef' calls (+ 1)
        map Redeemer.argument (redeemers tx) @?= [argument]
        pure (Evaluation.mkBudgets [(Evaluation.RedeemerId Redeemer.Minting 0, ExUnits 100 200)])
      plan =
        Plan.spend input
          <> Plan.payTo output
          <> Plan.attachScript script
          <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 2), (second, 3)] (\_ _ -> Right argument)
  tx <- Builder.build config {Builder.evaluator = Just checked} plan >>= must
  map Redeemer.argument (redeemers tx) @?= [argument]
  let outputs = foldMap Output.value (Fields.fieldOutputs (Body.bodyFields (Body.toBody (Tx.body tx))))
  Value.quantity (Asset.Native policy AssetName.empty) outputs @?= 2
  Value.quantity (Asset.Native policy second) outputs @?= 3
  count <- readIORef calls
  assertBool "no balancing evaluation" (count > 0)

otherPurposes :: IO ()
otherPurposes = do
  (config, output, locked, script) <- scriptFixture
  funding <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 10000000) Datum.NoDatum Nothing)
  let input = Utxo.utxo (Utxo.input locked) funding
  hash <- Script.hash script >>= must
  let credential = Credential.ScriptCredential hash
      reward = Reward.fromCredential Network.testnet credential
      cert = Certificate.StakeDeregistration credential
      callback tag tx _ = Right (Data.fromData (Data.Constr tag [Data.Integer (toInteger (Body.fee (Body.toBody (Tx.body tx))))]))
      plan =
        Plan.spend input
          <> Plan.payTo output
          <> Plan.attachScript script
          <> Plan.withdrawWithDeferredRedeemer reward 0 (callback 1)
          <> Plan.certificateWithDeferredRedeemer cert (callback 2)
  tx <- Builder.build config plan >>= must
  map Redeemer.purpose (redeemers tx) @?= [Redeemer.Certifying, Redeemer.Rewarding]
  let fee = Data.Integer (toInteger (Body.fee (Body.toBody (Tx.body tx))))
  map Redeemer.argument (redeemers tx) @?= [Data.fromData (Data.Constr 2 [fee]), Data.fromData (Data.Constr 1 [fee])]

emptyMint :: IO ()
emptyMint = do
  (config, output, _) <- fixture
  policy <- must (Policy.fromBytes (B.replicate 28 1))
  let never _ _ = throw (userError "unused deferred callback")
      payment = Plan.payTo output
      empty = Plan.mintWithDeferredRedeemer policy [] never
      zero = Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 5), (AssetName.empty, -5)] never
  ordinary <- Builder.build config payment >>= must
  Builder.build config (payment <> empty <> zero) >>= (@?= Right ordinary)

conflicts :: IO ()
conflicts = do
  (config, output, input, script) <- scriptFixture
  hash <- Script.hash script >>= must
  policy <- must (Policy.fromBytes (Credential.scriptHashBytes hash))
  let argument = Data.fromData (Data.Integer 1)
      callback _ _ = Right argument
      deferred = Plan.spendWithDeferredRedeemer input callback Nothing
      minted = Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] callback
      reward = Reward.fromCredential Network.testnet (Credential.ScriptCredential hash)
      withdrawal = Plan.withdrawWithDeferredRedeemer reward 0 callback
      plans =
        [ deferred <> deferred,
          deferred <> Plan.spend input,
          minted <> minted,
          minted <> Plan.mint (Asset.Native policy AssetName.empty) 1,
          withdrawal <> withdrawal
        ]
  mapM_ (\plan -> Builder.build config (plan <> Plan.payTo output) >>= assertBool "conflict accepted" . isLeft) plans

failures :: IO ()
failures = do
  baseline <- Runtime.liveContexts
  (config, output, input, script) <- scriptFixture
  let plan callback = Plan.spendWithDeferredRedeemer input callback Nothing <> Plan.payTo output <> Plan.attachScript script
      expected = InvalidTransactionPlan "deferred callback refused draft"
  Builder.build config (plan (\_ _ -> Left expected)) >>= (@?= Left expected)
  let lazyFailure _ _ = Right (Data.fromData (Data.List [Data.Integer (throw (userError "lazy deferred payload"))]))
  outcome <- try (Builder.build config (plan lazyFailure))
  case outcome of
    Left (failure :: SomeException) -> assertBool "lazy exception lost" ("lazy deferred payload" `isInfixOf` displayException failure)
    Right result -> assertFailure ("lazy exception returned normally: " <> show result)
  Runtime.liveContexts >>= (@?= baseline)

cancellation :: IO ()
cancellation = do
  baseline <- Runtime.liveContexts
  (config, output, input, script) <- scriptFixture
  let never _ _ = Right (Data.fromData (Data.Integer (sum [1 ..])))
      plan = Plan.spendWithDeferredRedeemer input never Nothing <> Plan.payTo output <> Plan.attachScript script
  outcome <- timeout 200000 (Builder.build config plan)
  outcome @?= Nothing
  Runtime.liveContexts >>= (@?= baseline)

{-# ANN laws ("HLint: ignore Monoid law, left identity" :: String) #-}
{-# ANN laws ("HLint: ignore Monoid law, right identity" :: String) #-}
laws :: IO ()
laws = do
  (_, _, input, _) <- scriptFixture
  let callback _ _ = Right (Data.fromData (Data.Integer 1))
      x = Plan.spendWithDeferredRedeemer input callback Nothing
      y = Plan.validFrom 10 <> Plan.spendWithDeferredRedeemer input (\_ _ -> Right (Data.fromData (Data.Integer 2))) Nothing
      z = Plan.spendWithDeferredRedeemer input (\_ _ -> Right (Data.fromData (Data.Integer 3))) Nothing <> Plan.validUntil 100
      observe = InternalPlan.encodePlan
  observe ((x <> y) <> z) @?= observe (x <> (y <> z))
  observe (mempty <> x) @?= observe x
  observe (x <> mempty) @?= observe x

nativeMinting :: IO ()
nativeMinting = do
  (config, output, _) <- fixture
  script <- must (Plutus.fromBytes Plutus.V4 (B.pack [0x45, 1, 1, 0, 0x24, 0x99]))
  hash <- Plutus.hash script >>= must
  model <- must (Models.mkCostModel 3 (replicate 369 100))
  collateralId <- must (Id.fromBytes (B.replicate 32 9))
  collateral <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 5000000) Datum.NoDatum Nothing)
  let policy = Policy.fromScriptHash hash
      params =
        (Builder.parameters config)
          { P.parameterProtocolVersion = Version.ProtocolVersion 12 0,
            P.parameterCostModels = Just (Models.fromList [model]),
            P.parameterMaxTxExUnits = Just (ExUnits 100000000 100000000000)
          }
      configured =
        config
          { Builder.parameters = params,
            Builder.collateralUtxos = [Utxo.utxo (Input.input collateralId 0) collateral]
          }
      callback tx _ = Right (Data.fromData (Data.Integer (toInteger (Body.fee (Body.toBody (Tx.body tx))))))
      plan =
        Plan.payTo output
          <> Plan.attachScript (Script.Plutus script)
          <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] callback
  tx <- Builder.build configured plan >>= must
  let expected = Data.fromData (Data.Integer (toInteger (Body.fee (Body.toBody (Tx.body tx)))))
  map Redeemer.argument (redeemers tx) @?= [expected]
  assertBool "native evaluator left zero budgets" (all ((/= ExUnits 0 0) . Redeemer.executionUnits) (redeemers tx))
