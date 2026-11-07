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

-- | Offline native-builder tests. Expected balances use independent integer
-- accounting; inputs are synthetic and never query or submit to a network.
module TransactionBuilder (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.CoinSelection as Selection
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionPlan as InternalPlan
import qualified Cometa.Metadata as Metadata
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.ExUnitPrices as Prices
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
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
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, finally, throwIO, try)
import Control.Monad (forM_, replicateM_, (>=>))
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Fixtures.ProtocolParameters as Fixture
import Hedgehog (Property, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Transaction building"
    [ testCase "payment order, multiplicity and independent balance oracle" payment,
      testCase "many mandatory inputs sharing one key keep one witness reserve" sharedKey,
      testCase "injected selection crosses actual balancing callbacks repeatedly" callbacks,
      testCase "native script minting, metadata, certificates and withdrawal" fields,
      testCase "composed script attachments are unique by language and exact program" uniqueScripts,
      testCase "datum witnesses are shared across explicit attachments and inputs" uniqueDatums,
      testCase "injected evaluator installs budgets in a complete script spend" scripts,
      testCase "preflight conflicts and native insufficient funds" invalid,
      testCase "surplus withdrawals and minted change cross injected selection" surplus,
      testCase "aggregate native arithmetic and witness padding fail before callbacks" bounds,
      testCase "expected callback error and thrown exceptions preserve identity" failures,
      testCase "cancellation joins callback cleanup and restores allocation baseline" cancellation,
      testProperty "plan associativity and identity" laws
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

semantic :: Tx.Transaction -> Fields.Fields
semantic = Body.bodyFields . Body.toBody . Tx.body

payment :: IO ()
payment = do
  (config, output, input) <- fixture
  let plan = Plan.payTo output <> Plan.payTo output <> Plan.validFrom 10 <> Plan.validFrom 20 <> Plan.validUntil 100 <> Plan.validUntil 80
  tx <- Builder.build config plan >>= must
  let actual = semantic tx
  Fields.fieldInputs actual @?= [Utxo.input input]
  take 2 (Fields.fieldOutputs actual) @?= [output, output]
  foldMap Output.value (drop 2 (Fields.fieldOutputs actual)) @?= Value.lovelace 5800000
  Body.fee (Body.toBody (Tx.body tx)) @?= 200000
  Fields.fieldInvalidBefore actual @?= Just 20
  Fields.fieldInvalidAfter actual @?= Just 80
  Fields.fieldNetworkId actual @?= Just Fields.Testnet
  Tx.decodeCbor (Tx.encodeCbor tx) @?= Right tx
  overlap <- Builder.build config (Plan.spend input <> Plan.payTo output) >>= must
  Fields.fieldInputs (semantic overlap) @?= [Utxo.input input]
  foldMap Output.value (Fields.fieldOutputs (semantic overlap)) @?= Value.lovelace 9800000

sharedKey :: IO ()
sharedKey = do
  (config, output, wallet) <- fixture
  let previous = Input.transactionId (Utxo.input wallet)
  tiny <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 1000000) Datum.NoDatum Nothing)
  let inputs = [Utxo.utxo (Input.input previous ix) tiny | ix <- [0 .. 299]]
      plan = foldMap Plan.spend inputs <> Plan.payTo output
  tx <- Builder.build config {Builder.availableUtxos = []} plan >>= must
  length (Fields.fieldInputs (semantic tx)) @?= 300
  assertBool "fixture transaction should fit16KiB" (B.length (Tx.encodeCbor tx) + 101 < 16384)

spendAll :: Selection.Selector
spendAll = Selection.Selector $ \request -> pure $ do
  let selected = Map.elems (Map.fromList [(Utxo.input u, u) | u <- Selection.preselected request <> Selection.available request])
      total = foldMap (Output.value . Utxo.output) selected
      excess = Value.difference total (Selection.target request)
  change <- if Value.isZero excess then pure [] else (: []) <$> Output.mkOutput (Selection.changeAddress request) excess Datum.NoDatum Nothing
  pure (Selection.Selection selected [] change)

callbacks :: IO ()
callbacks = do
  baseline <- Runtime.liveContexts
  (config, output, _) <- fixture
  calls <- newIORef (0 :: Int)
  let selected = Selection.Selector $ \request -> do
        modifyIORef' calls (+ 1)
        performGC
        Selection.select spendAll request
      injected = config {Builder.selector = Just selected}
  replicateM_ 3 (Builder.build injected (Plan.payTo output) >>= must)
  count <- readIORef calls
  assertBool "selection not called for each build" (count >= 3)
  Runtime.liveContexts >>= (@?= baseline)

fields :: IO ()
fields = do
  (config, output, _) <- fixture
  stake <- must (Credential.keyHashFromBytes (B.replicate 28 9))
  let script = Script.Native (Native.allOf [])
  scriptHash <- Script.hash script >>= must
  policy <- must (Policy.fromBytes (Credential.scriptHashBytes scriptHash))
  metadatum <- must (Metadata.mkInteger 42)
  let asset = Asset.Native policy AssetName.empty
      credential = Credential.KeyCredential stake
      reward = Reward.fromCredential Network.testnet credential
      cert = Certificate.StakeRegistration credential
      datum = Data.fromData (Data.Integer 42)
      plan =
        Plan.payTo output
          <> Plan.attachScript script
          <> Plan.mint asset 1
          <> Plan.mint asset 1
          <> Plan.metadata 7 metadatum
          <> Plan.attachDatum datum
          <> Plan.certificate cert
          <> Plan.withdraw reward 1000000
  tx <- Builder.build config plan >>= must
  let actual = semantic tx
  fmap (Value.quantity asset . Fields.mintValue) (Fields.fieldMint actual) @?= Just 2
  fmap Certificates.toList (Fields.fieldCertificates actual) @?= Just [cert]
  fmap Fields.entries (Fields.fieldWithdrawals actual) @?= Just [(reward, 1000000)]
  let outputs = foldMap Output.value (Fields.fieldOutputs actual)
  Value.quantity Asset.Ada outputs @?= 8800000
  Value.quantity asset outputs @?= 2
  assertBool "auxiliary data missing" (isJust (Tx.auxiliaryData tx))
  assertBool "datum witness missing" (datum `elem` Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses tx)))
  where
    isJust Nothing = False; isJust (Just _) = True

scripts :: IO ()
scripts = do
  (config, output, wallet) <- fixture
  script <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V2 (B.pack [1, 2, 3]))
  model <- must (Models.mkCostModel 1 (replicate 175 0))
  hash <- Script.hash script >>= must
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.ScriptCredential hash))
      datum = Data.fromData (Data.Integer 42)
  locked <- must (Output.mkOutput destination (Value.lovelace 10000000) (Datum.InlineDatum datum) Nothing)
  let scriptInput = Utxo.utxo (Utxo.input wallet) locked
  collateralId <- must (Id.fromBytes (B.replicate 32 10))
  collateralOutput <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 5000000) Datum.NoDatum Nothing)
  calls <- newIORef (0 :: Int)
  let evaluate = Evaluation.Evaluator $ \target tx _ -> do
        target @?= Evaluation.TopLevel
        modifyIORef' calls (+ 1)
        pure
          ( Evaluation.mkBudgets
              [ (Evaluation.RedeemerId (Redeemer.purpose r) (Redeemer.index r), ExUnits 100 200)
              | r <- Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses tx))
              ]
          )
      injected = config {Builder.availableUtxos = [], Builder.collateralUtxos = [Utxo.utxo (Input.input collateralId 0) collateralOutput], Builder.evaluator = Just evaluate, Builder.parameters = (Builder.parameters config) {P.parameterCostModels = Just (Models.fromList [model])}}
  tx <- Builder.build injected (Plan.spendWith scriptInput (Just datum) Nothing <> Plan.attachScript script <> Plan.attachScript script <> Plan.attachDatum datum <> Plan.attachDatum datum <> Plan.payTo output) >>= must
  Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses tx)) @?= [datum]
  Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses tx)) @?= [script]
  assertBool "evaluator not called" . (> 0) =<< readIORef calls
  map Redeemer.executionUnits (Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses tx))) @?= [ExUnits 100 200]
  let tooSmall = injected {Builder.parameters = (Builder.parameters injected) {P.parameterMaxTxExUnits = Just (ExUnits 99 199)}}
  Builder.build tooSmall (Plan.spendWith scriptInput (Just datum) Nothing <> Plan.attachScript script <> Plan.payTo output)
    >>= (@?= Left (InvalidEvaluationResult "Evaluation exceeds maximum transaction execution units"))
  extreme <- must (Rational.mkNonNegativeRational (2 ^ (64 :: Int) - 1) 1)
  let overpriced = injected {Builder.parameters = (Builder.parameters injected) {P.parameterExecutionCosts = Just (Prices.ExUnitPrices extreme extreme)}}
  before <- readIORef calls
  Builder.build overpriced (Plan.spendWith scriptInput (Just datum) Nothing <> Plan.attachScript script <> Plan.payTo output)
    >>= assertBool "execution fee overflow accepted" . isLeft
  readIORef calls >>= (@?= before)
  baseline <- Runtime.liveContexts
  Builder.build injected {Builder.evaluator = Nothing} (Plan.spendWith scriptInput (Just datum) Nothing <> Plan.attachScript script <> Plan.payTo output)
    >>= assertBool "malformed script unexpectedly executed" . isLeft
  Runtime.liveContexts >>= (@?= baseline)

invalid :: IO ()
invalid = do
  (config, output, input) <- fixture
  one <- must (Metadata.mkInteger 1)
  two <- must (Metadata.mkInteger 2)
  forM_
    [ Plan.validFrom 10 <> Plan.validUntil 10,
      Plan.mint Asset.Ada 1,
      Plan.metadata 1 one <> Plan.metadata 1 two,
      Plan.spend input <> Plan.spendWith input (Just (Data.fromData (Data.Integer 0))) Nothing
    ]
    (Builder.build config >=> (assertBool "invalid plan accepted" . isLeft))
  Builder.build config {Builder.availableUtxos = []} (Plan.payTo output) >>= assertBool "unfunded build accepted" . isLeft

surplus :: IO ()
surplus = do
  (config, output, _) <- fixture
  stake <- must (Credential.keyHashFromBytes (B.replicate 28 9))
  let script = Script.Native (Native.allOf [])
  hash <- Script.hash script >>= must
  policy <- must (Policy.fromBytes (Credential.scriptHashBytes hash))
  let reward = Reward.fromCredential Network.testnet (Credential.KeyCredential stake)
      asset = Asset.Native policy AssetName.empty
      plan = Plan.payTo output <> Plan.withdraw reward 10000000 <> Plan.attachScript script <> Plan.mint asset 2
  tx <- Builder.build config {Builder.selector = Just spendAll} plan >>= must
  let total = foldMap Output.value (Fields.fieldOutputs (semantic tx))
  Value.quantity Asset.Ada total @?= 19800000
  Value.quantity asset total @?= 2
  cancelled <- Builder.build config (Plan.payTo output <> Plan.mint asset 1 <> Plan.mint asset (-1)) >>= must
  Fields.fieldMint (semantic cancelled) @?= Nothing

bounds :: IO ()
bounds = do
  (config, output, wallet) <- fixture
  huge <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace (2 ^ (62 :: Int))) Datum.NoDatum Nothing)
  let first = Utxo.utxo (Utxo.input wallet) huge
      second = Utxo.utxo (Input.input (Input.transactionId (Utxo.input wallet)) 1) huge
  restricted <- must (Slot.mkSlotConfig 0 100 1000)
  late <- must (Slot.mkSlotConfig maxBound 0 1)
  calls <- newIORef (0 :: Int)
  let backend = Selection.Selector (\request -> modifyIORef' calls (+ 1) >> Selection.select spendAll request)
      checked = config {Builder.selector = Just backend}
      cases =
        [ (checked {Builder.availableUtxos = [wallet, wallet]}, Plan.payTo output),
          (checked {Builder.collateralUtxos = [wallet, wallet]}, Plan.payTo output),
          (checked {Builder.availableUtxos = [first, second]}, Plan.payTo output),
          (checked, Plan.payTo huge <> Plan.payTo huge),
          (checked {Builder.minimumFee = 2 ^ (63 :: Int)}, Plan.payTo output),
          (checked {Builder.extraSigners = maxBound}, Plan.payTo output),
          (checked {Builder.slotConfig = restricted}, Plan.validFrom 99 <> Plan.payTo output),
          (checked {Builder.slotConfig = late}, Plan.validUntil 1 <> Plan.payTo output)
        ]
  forM_ cases $ \(context, plan) -> Builder.build context plan >>= assertBool "unsafe request accepted" . isLeft
  readIORef calls >>= (@?= 0)

failures :: IO ()
failures = do
  baseline <- Runtime.liveContexts
  (config, output, _) <- fixture
  let expected = UnsupportedOperation "selector refusal"
  Builder.build config {Builder.selector = Just (Selection.Selector (\_ -> pure (Left expected)))} (Plan.payTo output) >>= (@?= Left expected)
  outcome <- try (Builder.build config {Builder.selector = Just (Selection.Selector (\_ -> throwIO (userError "builder callback failure")))} (Plan.payTo output))
  case outcome of
    Left (failure :: SomeException) -> assertBool "exception identity" ("builder callback failure" `isInfixOf` displayException failure)
    Right _ -> assertFailure "callback exception swallowed"
  Runtime.liveContexts >>= (@?= baseline)

cancellation :: IO ()
cancellation = do
  baseline <- Runtime.liveContexts
  (config, output, _) <- fixture
  started <- newEmptyMVar
  block <- newEmptyMVar
  cleaned <- newEmptyMVar
  finished <- newEmptyMVar
  let selected = Selection.Selector $ \_ -> (putMVar started () >> takeMVar block) `finally` putMVar cleaned ()
  worker <- forkFinally (Builder.build config {Builder.selector = Just selected} (Plan.payTo output)) (putMVar finished)
  takeMVar started
  killThread worker
  joined <- timeout 5000000 (takeMVar finished)
  case joined of Just (Left _) -> pure (); _ -> assertFailure "build cancellation did not unwind"
  takeMVar cleaned
  Runtime.liveContexts >>= (@?= baseline)

{-# ANN laws ("HLint: ignore Monoid law, left identity" :: String) #-}
{-# ANN laws ("HLint: ignore Monoid law, right identity" :: String) #-}
laws :: Property
laws = property $ do
  a <- forAll (Gen.word64 (Range.linear 0 100000))
  b <- forAll (Gen.word64 (Range.linear 0 100000))
  c <- forAll (Gen.word64 (Range.linear 0 100000))
  let x = Plan.validFrom a; y = Plan.validUntil b; z = Plan.validFrom c
  InternalPlan.encodePlan ((x <> y) <> z) === InternalPlan.encodePlan (x <> (y <> z))
  InternalPlan.encodePlan (mempty <> x) === InternalPlan.encodePlan x
  InternalPlan.encodePlan (x <> mempty) === InternalPlan.encodePlan x

uniqueScripts :: IO ()
uniqueScripts = do
  (base, output, _) <- fixture
  let config = base {Builder.parameters = (Builder.parameters base) {P.parameterProtocolVersion = Version.ProtocolVersion 12 0}}
      nativeA = Script.Native (Native.allOf [])
      nativeB = Script.Native (Native.anyOf [])
      nativePlan = Plan.attachScript nativeB <> Plan.attachScript nativeA
  nativeTx <- Builder.build config (nativePlan <> nativePlan <> Plan.payTo output) >>= must
  Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses nativeTx)) @?= [nativeB, nativeA]
  versions <- mapM (\version -> Script.Plutus <$> must (Plutus.fromBytes version (B.pack [1, 2, 3]))) [Plutus.V1 .. Plutus.V4]
  allVersions <- Builder.build config (foldMap Plan.attachScript (versions <> versions) <> Plan.payTo output) >>= must
  Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses allVersions)) @?= versions
  forM_ [Plutus.V1 .. Plutus.V4] $ \version -> do
    canonical <- Script.Plutus <$> must (Plutus.fromBytes version (B.pack [1, 2, 3]))
    first <- Script.Plutus <$> must (Plutus.decodeCbor version (B.pack [0x58, 3, 1, 2, 3]))
    distinct <- Script.Plutus <$> must (Plutus.fromBytes version (B.pack [4, 5, 6]))
    let once = Plan.attachScript first <> Plan.attachScript distinct <> Plan.payTo output
        repeated = Plan.attachScript first <> Plan.attachScript distinct <> Plan.attachScript canonical <> Plan.attachScript first <> Plan.payTo output
    -- Keep the first exact imported framing in the native instruction stream.
    InternalPlan.encodePlan repeated @?= InternalPlan.encodePlan once
    expected <- Builder.build config once >>= must
    actual <- Builder.build config repeated >>= must
    Tx.encodeCbor actual @?= Tx.encodeCbor expected
    length (Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses actual))) @?= 2

uniqueDatums :: IO ()
uniqueDatums = do
  (config, output, first) <- fixture
  let second = Utxo.utxo (Input.input (Input.transactionId (Utxo.input first)) 1) (Utxo.output first)
      canonical = Data.fromData (Data.Integer 0)
  imported <- must (Data.decodeCbor (B.pack [0x18, 0]))
  Data.toData imported @?= Data.toData canonical
  let requirements = Plan.payTo output
      attachments = Plan.attachDatum imported <> Plan.attachDatum canonical <> Plan.attachDatum imported <> Plan.attachDatum canonical
  explicit <- Builder.build config (attachments <> requirements) >>= must
  Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses explicit)) @?= [imported, canonical]
  forM_ [False, True] $ \attachFirst -> do
    let spends = Plan.spendWith first Nothing (Just imported) <> Plan.spendWith second Nothing (Just imported)
        plan = if attachFirst then attachments <> spends <> requirements else spends <> attachments <> requirements
    tx <- Builder.build config plan >>= must
    Fields.fieldInputs (semantic tx) @?= [Utxo.input first, Utxo.input second]
    Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses tx)) @?= [imported, canonical]
  -- Conflicting declarations for one input still fail before deduplication.
  Builder.build config (Plan.spendWith first Nothing (Just imported) <> Plan.spendWith first Nothing (Just canonical) <> requirements)
    >>= (@?= Left (InvalidTransactionPlan "Conflicting requirements for one spending input"))
