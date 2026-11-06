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

module NativeEvaluation (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Evaluation.Native as Native
import qualified Cometa.Internal.Evaluation.Native as Internal
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.Value as Value
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException)
import Control.Monad (forM_, replicateM_)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Native evaluation"
    [ testCase "V1 through V4 execute without changing exact transaction bytes" successes,
      testCase "phase-2 and deserialisation failures retain status and diagnostics" failures,
      testCase "subtargets evaluate all levels with a global budget" subtargets,
      testCase "cost models determine consumed units" costModels,
      testCase "complete resolution and validity bounds are checked" validation,
      testCase "sublevel resolution and schedule endpoints are checked" subValidation,
      testCase "partial transport failures and repeated calls release resources" lifecycle,
      testCase "concurrent requests own independent evaluator state" concurrency
    ]

config :: Native.Config
config = Native.Config Slots.preview 12 Models.empty

run :: Native.Config -> Evaluation.Target -> Tx.Transaction -> IO (Either Error Evaluation.Budgets)
run context target tx = Evaluation.evaluate (Native.evaluator context) target tx []

-- Derived from Apache-2.0 cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1
-- lib/tests/uplc/native_tx_evaluator.cpp build_succeeds_program_cbor,
-- build_v3_script and build_v4_script. These are single-CBOR-wrapped Flat
-- lambda/unit and lambda/error programs, assembled below through public values.
program :: Plutus.Version -> Bool -> Text
program language succeeds = case (language, succeeds) of
  (Plutus.V1, True) -> "46010000224981"
  (Plutus.V1, False) -> "450100002261"
  (Plutus.V2, True) -> "46010000224981"
  (Plutus.V2, False) -> "450100002261"
  (Plutus.V4, True) -> "450101002499"
  (Plutus.V4, False) -> "450101002601"
  (_, True) -> "450100002499"
  (_, False) -> "450100002601"

mintLevel :: Plutus.Version -> Text -> IO (Either Error (Fields.Fields, Witnesses.EncodedWitnesses))
mintLevel language code = runExceptT $ do
  bytes <- except (maybe (Left InvalidHex) Right (Hex.decodeHex code))
  script <- except (Plutus.fromBytes language bytes)
  digest <- ExceptT (Plutus.hash script)
  mint <- except (Fields.mkMint (Value.singleton (AssetId.Native (Policy.fromScriptHash digest) AssetName.empty) 1))
  argument <- except (Data.decodeCbor (B.pack [0x18, 0]))
  witnesses <- except (Witnesses.mkWitnesses [] [] [Script.Plutus script] [] [Redeemer.Redeemer Redeemer.Minting 0 argument (ExUnits 9 11)])
  pure ((Fields.fields [] []) {Fields.fieldMint = Just mint}, Witnesses.fromWitnesses witnesses)

transaction :: Plutus.Version -> Text -> IO Tx.Transaction
transaction language code = do
  (fields, witnesses) <- mintLevel language code >>= require
  body <- require (Body.fromBody (Body.body [] [] 0) {Body.bodyFields = fields})
  pure (Tx.assemble body witnesses Nothing)

successes :: IO ()
successes = forM_ [minBound .. maxBound] $ \language -> do
  original <- transaction language (program language True)
  let bytes = B.singleton 0x9f <> B.drop 1 (Tx.encodeCbor original) <> B.singleton 0xff
  tx <- require (Tx.decodeCbor bytes)
  result <- run config Evaluation.TopLevel tx >>= require
  case Evaluation.budgets result of
    [(Evaluation.RedeemerId Redeemer.Minting 0, ExUnits consumedMemory consumedSteps)] -> assertBool "positive consumed units" (consumedMemory > 0 && consumedSteps > 0)
    other -> assertFailure (show other)
  Tx.encodeCbor tx @?= bytes
  map Redeemer.executionUnits (Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses tx))) @?= [ExUnits 9 11]

failures :: IO ()
failures = do
  forM_ [minBound .. maxBound] $ \language -> do
    tx <- transaction language (program language False)
    run config Evaluation.TopLevel tx >>= expectNative Code.ScriptEvaluationFailure
  malformed <- transaction Plutus.V4 "41ff"
  run config Evaluation.TopLevel malformed >>= expectNative Code.DecodingFailure
  unavailable <- transaction Plutus.V4 (program Plutus.V4 True)
  run config {Native.protocolMajor = 10} Evaluation.TopLevel unavailable >>= expectNative Code.DecodingFailure

withSub :: Tx.Transaction -> Plutus.Version -> Bool -> IO Tx.Transaction
withSub tx language succeeds = do
  (fields, witnesses) <- mintLevel language (program language succeeds) >>= require
  subBody <- require (SubBody.fromBody (SubBody.fromFields fields))
  body <- require (Body.fromBody (Body.toBody (Tx.body tx)) {Body.bodySubTransactions = Just [Sub.assemble subBody witnesses Nothing]})
  pure (Tx.assemble body (Tx.witnesses tx) Nothing)

subtargets :: IO ()
subtargets = do
  top <- transaction Plutus.V4 (program Plutus.V4 True)
  tx <- withSub top Plutus.V4 True
  expected <- run config Evaluation.TopLevel tx >>= require
  run config (Evaluation.SubTransaction 0) tx >>= (@?= Right expected)
  run config (Evaluation.SubTransaction maxBound) tx >>= assertBool "target bounds" . isLeft
  bad <- withSub top Plutus.V4 False
  run config Evaluation.TopLevel bad >>= expectNative Code.ScriptEvaluationFailure
  run config (Evaluation.SubTransaction 0) bad >>= expectNative Code.ScriptEvaluationFailure
  old <- withSub top Plutus.V3 True
  run config Evaluation.TopLevel old >>= expectNative Code.InvalidScriptLanguage
  expensive <- require (Models.mkCostModel 3 (replicate 251 12000000))
  let limited = config {Native.costModels = Models.fromList [expensive]}
  run limited Evaluation.TopLevel top >>= require >>= \units -> assertBool "one expensive script fits" (not (null (Evaluation.budgets units)))
  run limited Evaluation.TopLevel tx >>= expectNative Code.ScriptEvaluationFailure

costModels :: IO ()
costModels = do
  tx <- transaction Plutus.V4 (program Plutus.V4 True)
  actual <- run config Evaluation.TopLevel tx >>= require
  map snd (Evaluation.budgets actual) @?= [ExUnits 500 64100]
  model <- require (Models.mkCostModel 3 (replicate 251 200))
  custom <- run config {Native.costModels = Models.fromList [model]} Evaluation.TopLevel tx >>= require
  map snd (Evaluation.budgets custom) @?= [ExUnits 1000 1000]
  invalid <- require (Models.mkCostModel 3 [1])
  run config {Native.costModels = Models.fromList [invalid]} Evaluation.TopLevel tx >>= assertBool "invalid model rejected" . isLeft

validation :: IO ()
validation = do
  resolved <- require (maybe (Left InvalidHex) Utxo.decodeCbor (Hex.decodeHex "8282582000000000000000000000000000000000000000000000000000000000000000000082581d600000000000000000000000000000000000000000000000000000000001"))
  let input = Utxo.input resolved
  body <- require (Body.fromBody (Body.body [input] [] 0))
  let tx = Tx.fromBody body
  run config Evaluation.TopLevel tx >>= assertBool "missing spending input" . isLeft
  empty <- require (Evaluation.mkBudgets [])
  Evaluation.evaluate (Native.evaluator config) Evaluation.TopLevel tx [resolved] >>= (@?= Right empty)
  Evaluation.evaluate (Native.evaluator config) Evaluation.TopLevel tx [resolved, resolved] >>= assertBool "duplicate resolution" . isLeft
  let fields = (Fields.fields [] []) {Fields.fieldReferenceInputs = Just [input]}
  refBody <- require (Body.fromBody (Body.body [] [] 0) {Body.bodyFields = fields})
  run config Evaluation.TopLevel (Tx.fromBody refBody) >>= assertBool "missing reference input" . isLeft
  forM_ [fields {Fields.fieldInvalidAfter = Just maxBound}, fields {Fields.fieldInvalidBefore = Just maxBound}] $ \bounds -> do
    bounded <- require (Body.fromBody (Body.body [] [] 0) {Body.bodyFields = bounds {Fields.fieldReferenceInputs = Nothing}})
    run config Evaluation.TopLevel (Tx.fromBody bounded) >>= assertBool "slot overflow" . isLeft

subValidation :: IO ()
subValidation = do
  resolved <- require (maybe (Left InvalidHex) Utxo.decodeCbor (Hex.decodeHex "8282582000000000000000000000000000000000000000000000000000000000000000000082581d600000000000000000000000000000000000000000000000000000000001"))
  empty <- require (Evaluation.mkBudgets [])
  top <- require (Body.fromBody (Body.body [] [] 0))
  Evaluation.evaluate (Native.evaluator config) Evaluation.TopLevel (Tx.fromBody top) [resolved] >>= (@?= Right empty)
  let reference = Utxo.input resolved
      incomplete = (Fields.fields [reference] []) {Fields.fieldReferenceInputs = Just [reference]}
  subBody <- require (SubBody.fromBody (SubBody.fromFields incomplete))
  body <- require (Body.fromBody (Body.body [] [] 0) {Body.bodySubTransactions = Just [Sub.assemble subBody (Witnesses.fromWitnesses Witnesses.empty) Nothing]})
  let tx = Tx.fromBody body
  run config Evaluation.TopLevel tx >>= assertBool "missing sublevel resolution" . isLeft
  Evaluation.evaluate (Native.evaluator config) (Evaluation.SubTransaction 0) tx [resolved] >>= (@?= Right empty)
  belowReference <- require (SubBody.fromBody (SubBody.fromFields ((Fields.fields [] []) {Fields.fieldInvalidBefore = Just 0})))
  earlyBody <- require (Body.fromBody (Body.body [] [] 0) {Body.bodySubTransactions = Just [Sub.assemble belowReference (Witnesses.fromWitnesses Witnesses.empty) Nothing]})
  run config {Native.slotConfig = Slots.mainnet} Evaluation.TopLevel (Tx.fromBody earlyBody) >>= assertBool "sublevel slot before reference" . isLeft
  extreme <- require (Slots.mkSlotConfig maxBound 0 1)
  endBody <- require (Body.fromBody (Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldInvalidAfter = Just 0}})
  run config {Native.slotConfig = extreme} Evaluation.TopLevel (Tx.fromBody endBody) >>= (@?= Right empty)

lifecycle :: IO ()
lifecycle = do
  tx <- transaction Plutus.V4 (program Plutus.V4 True)
  replicateM_ 20 $ do
    run config Evaluation.TopLevel tx >>= require >>= \units -> assertBool "repeat" (not (null (Evaluation.budgets units)))
    Internal.runUnchecked config Evaluation.TopLevel (Tx.encodeCbor tx <> B.singleton 0) (B.singleton 0x80) >>= assertBool "trailing tx" . isLeft
    Internal.runUnchecked config Evaluation.TopLevel (Tx.encodeCbor tx) (B.pack [0x81, 0]) >>= assertBool "partial UTxO" . isLeft

concurrency :: IO ()
concurrency = do
  tx <- transaction Plutus.V4 (program Plutus.V4 True)
  first <- newEmptyMVar
  second <- newEmptyMVar
  let execute slot = do
        _ <- forkFinally (run config Evaluation.TopLevel tx) (putMVar slot)
        pure ()
  execute first
  execute second
  left <- takeMVar first >>= joined
  right <- takeMVar second >>= joined
  left @?= right
  where
    joined :: Either SomeException (Either Error Evaluation.Budgets) -> IO Evaluation.Budgets
    joined = either (\failure -> assertFailure (show failure) >> fail "unreachable") require

expectNative :: Code.ErrorCode -> Either Error a -> IO ()
expectNative expected result = case result of
  Left (NativeError operation status diagnostic) -> do
    operation @?= "evaluation.native"
    status @?= expected
    assertBool "copied native diagnostic" (not (Text.null diagnostic))
  other -> case other of
    Left failure -> assertFailure (show failure)
    Right _ -> assertFailure "expected native failure"

require :: Either Error a -> IO a
require = either (\failure -> assertFailure (show failure) >> fail "unreachable") pure
