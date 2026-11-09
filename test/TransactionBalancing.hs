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

-- | Offline rebalancing of imported transaction snapshots through public values.
module TransactionBalancing (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.CoinSelection as Selection
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.PublicKey as Key
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Metadata as Metadata
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Balancing as Balancing
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, readMVar, threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeException, displayException, fromException, throw, try)
import Control.Monad (forM_, replicateM_)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (elemIndex, isInfixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Word (Word8)
import qualified DeferredRedeemer as Fixture
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Contextual transaction balancing"
    [ testCase "payment snapshots retain original outputs and strip obsolete outer signatures" payment,
      testCase "change destination does not overwrite the imported body network" network,
      testCase "selected inputs remap immediate redeemers while retaining nonminimal argument CBOR" immediate,
      testCase "deferred spending payloads see final indices and selected snapshots" deferred,
      testCase "missing and stale script-data hashes use final redeemers and only required V2 views" scriptCommitments,
      testCase "datum-only script-data commitments use empty language views" datumCommitments,
      testCase "numeric balancing bounds fail before selector callbacks" numericBounds,
      testCase "callback errors and lazy exceptions retain identity and release contexts" failures,
      testCase "cancellation propagates ThreadKilled and joins deferred balancing contexts" cancellation,
      testCase "max-int64 token transfers bound spending and production independently" maximumTokenTransfer,
      testCase "missing and conflicting resolved snapshots fail before selection" invalidSnapshots,
      testCase "reference and collateral snapshots are mandatory" contextualInputs,
      testCase "resolved and collateral snapshots do not authorize extra spending" fundingAuthority,
      testCase "selector candidates exclude outer spending and reference inputs" selectorCandidates,
      testCase "malformed and unmatched redeemer identifiers fail before callbacks" invalidRedeemers,
      testCase "nested signed content and reference snapshots survive outer balancing" nested,
      testCase "indefinite nested envelope retains signed body and witnesses without requiring full-frame identity" nestedIndefinite
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

semantic :: Tx.Transaction -> Body.Body
semantic = Body.toBody . Tx.body

fields :: Tx.Transaction -> Fields.Fields
fields = Body.bodyFields . semantic

redeemers :: Tx.Transaction -> [Redeemer.Redeemer]
redeemers = Witnesses.redeemers . Witnesses.toWitnesses . Tx.witnesses

funding :: Builder.Config -> Word8 -> Integer -> IO Utxo.Utxo
funding configured seed amount = do
  identifier <- must (Id.fromBytes (B.replicate 32 seed))
  output <- must (Output.mkOutput (Builder.changeAddress configured) (Value.lovelace amount) Datum.NoDatum Nothing)
  pure (Utxo.utxo (Input.input identifier 0) output)

spendAll :: Selection.Selector
spendAll = Selection.Selector $ \request -> pure $ do
  let selected = Map.elems (Map.fromList [(Utxo.input input, input) | input <- Selection.preselected request <> Selection.available request])
      total = foldMap (Output.value . Utxo.output) selected
      excess = Value.difference total (Selection.target request)
  change <- if Value.isZero excess then pure [] else (: []) <$> Output.mkOutput (Selection.changeAddress request) excess Datum.NoDatum Nothing
  pure (Selection.Selection selected [] change)

payment :: IO ()
payment = do
  (configured, output, wallet) <- Fixture.fixture
  original <- Builder.build configured (Plan.payTo output) >>= must
  key <- must (Key.fromBytes (B.replicate 32 7))
  signature <- must (Signature.fromBytes (B.replicate 64 9))
  bootstrap <- must (Witness.mkBootstrapWitness key signature (B.replicate 32 10) "\160")
  signed <- must (Witnesses.mkWitnesses [Witness.verificationWitness key signature] [bootstrap] [] [] [])
  let imported = Tx.setWitnesses (Witnesses.fromWitnesses signed) original
      bytes = Tx.encodeCbor imported
      originalOutputs = Fields.fieldOutputs (fields imported)
  extra <- funding configured 1 3000000
  balanced <- Balancing.balance configured {Builder.minimumFee = 400000, Builder.availableUtxos = [extra], Builder.selector = Just spendAll} [wallet] imported >>= must
  Tx.encodeCbor imported @?= bytes
  take (length originalOutputs) (Fields.fieldOutputs (fields balanced)) @?= originalOutputs
  -- Existing change is an ordinary imported output, so additional funding is
  -- needed to raise the fee; that output must not be silently spent or reduced.
  Body.fee (semantic balanced) @?= 400000
  Fields.fieldInputs (fields balanced) @?= sort [Utxo.input extra, Utxo.input wallet]
  foldMap Output.value (drop (length originalOutputs) (Fields.fieldOutputs (fields balanced))) @?= Value.lovelace 2800000
  Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses balanced)) @?= []
  Witnesses.bootstrapWitnesses (Witnesses.toWitnesses (Tx.witnesses balanced)) @?= []
  Tx.decodeCbor (Tx.encodeCbor balanced) @?= Right balanced

network :: IO ()
network = do
  (configured, output, wallet) <- Fixture.fixture
  key <- must (Credential.keyHashFromBytes (B.replicate 28 3))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.mainnet (Credential.KeyCredential key))
      body = (Body.body [Utxo.input wallet] [output] 0) {Body.bodyFields = (Fields.fields [Utxo.input wallet] [output]) {Fields.fieldNetworkId = Just Fields.Testnet}}
  imported <- Tx.fromBody <$> must (Body.fromBody body)
  balanced <- Balancing.balance configured {Builder.changeAddress = destination, Builder.availableUtxos = []} [wallet] imported >>= must
  Fields.fieldNetworkId (fields balanced) @?= Just Fields.Testnet
  take 1 (Fields.fieldOutputs (fields balanced)) @?= [output]
  map Output.address (drop 1 (Fields.fieldOutputs (fields balanced))) @?= [destination]

scriptDraft :: IO (Builder.Config, Utxo.Utxo, Utxo.Utxo, Tx.Transaction)
scriptDraft = do
  (configured, output, locked, script) <- Fixture.scriptFixture
  let argument = Data.fromData (Data.Integer 77)
  original <- Builder.build configured (Plan.spendWith locked (Just argument) Nothing <> Plan.attachScript script <> Plan.payTo output) >>= must
  extra <- funding configured 1 3000000
  pure (configured {Builder.minimumFee = 400000, Builder.availableUtxos = [extra], Builder.selector = Just spendAll}, locked, extra, original)

immediate :: IO ()
immediate = do
  (configured, locked, extra, canonical) <- scriptDraft
  argument <- must (Data.decodeCbor (B.pack [0x18, 0x01]))
  let oldWitnesses = Witnesses.toWitnesses (Tx.witnesses canonical)
  importedWitnesses <-
    must
      ( Witnesses.mkWitnesses
          (Witnesses.verificationWitnesses oldWitnesses)
          (Witnesses.bootstrapWitnesses oldWitnesses)
          (Witnesses.scripts oldWitnesses)
          (Witnesses.datums oldWitnesses)
          [redeemer {Redeemer.argument = argument} | redeemer <- Witnesses.redeemers oldWitnesses]
      )
  let original = Tx.setWitnesses (Witnesses.fromWitnesses importedWitnesses) canonical
  calls <- newIORef (0 :: Int)
  selections <- newIORef (0 :: Int)
  let selected = Selection.Selector $ \request -> do
        modifyIORef' selections (+ 1)
        Selection.select spendAll request
      checked = Evaluation.Evaluator $ \_ draft resolvedInputs -> do
        modifyIORef' calls (+ 1)
        map Redeemer.index (redeemers draft) @?= [1]
        map (Data.toCbor . Redeemer.argument) (redeemers draft) @?= [B.pack [0x18, 0x01]]
        assertBool "evaluator receives newly selected snapshot" (extra `elem` resolvedInputs)
        pure (Evaluation.mkBudgets [(Evaluation.RedeemerId Redeemer.Spending 1, ExUnits 100 200)])
      bytes = Tx.encodeCbor original
  balanced <- Balancing.balance configured {Builder.evaluator = Just checked, Builder.selector = Just selected} (locked : Builder.collateralUtxos configured) original >>= must
  Fields.fieldInputs (fields balanced) @?= sort [Utxo.input extra, Utxo.input locked]
  map Redeemer.index (redeemers balanced) @?= [1]
  map (Data.toCbor . Redeemer.argument) (redeemers balanced) @?= [B.pack [0x18, 0x01]]
  map Redeemer.executionUnits (redeemers balanced) @?= [ExUnits 100 200]
  readIORef calls >>= assertBool "injected evaluator was called" . (> 0)
  readIORef selections >>= assertBool "injected selector was called" . (> 0)
  Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses balanced)) @?= Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses original))
  Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses balanced)) @?= Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses original))
  required <- v2Models configured
  assertCommitment required balanced
  Tx.encodeCbor original @?= bytes

deferred :: IO ()
deferred = do
  baseline <- Runtime.liveContexts
  (configured, locked, _, original) <- scriptDraft
  let callback draft selected = do
        let canonical = Fields.fieldInputs (fields draft)
        if map Utxo.input selected /= sort canonical
          then Left (InvalidTransactionPlan "noncanonical selected rebalancing snapshots")
          else case elemIndex (Utxo.input locked) canonical of
            Nothing -> Left (InvalidTransactionPlan "original script input disappeared")
            Just index -> Right (Data.fromData (Data.Constr 0 [Data.Integer (toInteger index)]))
      overrides = Map.singleton (Evaluation.RedeemerId Redeemer.Spending 0) callback
  balanced <- Balancing.balanceWithRedeemers configured (locked : Builder.collateralUtxos configured) overrides original >>= must
  map Redeemer.index (redeemers balanced) @?= [1]
  map Redeemer.argument (redeemers balanced) @?= [Data.fromData (Data.Constr 0 [Data.Integer 1])]
  required <- v2Models configured
  assertCommitment required balanced
  Runtime.liveContexts >>= (@?= baseline)

v2Models :: Builder.Config -> IO Models.CostModels
v2Models configured = case Parameters.parameterCostModels (Builder.parameters configured) >>= Models.lookup 1 of
  Just model -> pure (Models.fromList [model])
  Nothing -> assertFailure "V2 fixture model missing" >> fail "fixture"

assertCommitment :: Models.CostModels -> Tx.Transaction -> IO ()
assertCommitment models transaction = do
  expected <- Building.scriptDataHash models (Tx.witnesses transaction) >>= must
  Fields.fieldScriptDataHash (fields transaction) @?= expected

unusedLanguages :: IO ([Script.Script], [Models.CostModel])
unusedLanguages = do
  v1 <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V1 (B.pack [7, 8, 9]))
  v3 <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V3 (B.pack [10, 11, 12]))
  v1Model <- must (Models.mkCostModel 0 (replicate 166 0))
  v3Model <- must (Models.mkCostModel 2 (replicate 297 0))
  pure ([v1, v3], [v1Model, v3Model])

scriptCommitments :: IO ()
scriptCommitments = do
  (configured, locked, _, original) <- scriptDraft
  required <- v2Models configured
  (unusedScripts, unusedModels) <- unusedLanguages
  referenceId <- must (Id.fromBytes (B.replicate 32 44))
  referenceScript <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V3 (B.pack [15, 16, 17]))
  referenceOutput <- must (Output.mkOutput (Builder.changeAddress configured) (Value.lovelace 3000000) Datum.NoDatum (Just referenceScript))
  stale <- must (Datum.hashFromBytes (B.replicate 32 255))
  let reference = Utxo.utxo (Input.input referenceId 0) referenceOutput
      models = Models.fromList (Models.toList required <> unusedModels)
      context = configured {Builder.parameters = (Builder.parameters configured) {Parameters.parameterCostModels = Just models}}
      oldWitnesses = Witnesses.toWitnesses (Tx.witnesses original)
      changed = [redeemer {Redeemer.argument = Data.fromData (Data.Integer 999), Redeemer.executionUnits = ExUnits 7 11} | redeemer <- Witnesses.redeemers oldWitnesses]
  witnessSet <- must (Witnesses.mkWitnesses [] [] (Witnesses.scripts oldWitnesses <> unusedScripts) (Witnesses.datums oldWitnesses) changed)
  forM_ [Nothing, Just stale] $ \commitment -> do
    let replacement =
          (semantic original)
            { Body.bodyFields =
                (fields original)
                  { Fields.fieldReferenceInputs = Just [Utxo.input reference],
                    Fields.fieldScriptDataHash = commitment
                  }
            }
    encoded <- must (Body.fromBody replacement)
    let imported = Tx.setWitnesses (Witnesses.fromWitnesses witnessSet) (Tx.setBody encoded original)
        bytes = Tx.encodeCbor imported
    balanced <- Balancing.balance context (locked : reference : Builder.collateralUtxos context) imported >>= must
    map Redeemer.index (redeemers balanced) @?= [1]
    map Redeemer.argument (redeemers balanced) @?= [Data.fromData (Data.Integer 999)]
    map Redeemer.executionUnits (redeemers balanced) @?= [ExUnits 100 200]
    assertCommitment required balanced
    allViews <- Building.scriptDataHash models (Tx.witnesses balanced) >>= must
    assertBool "unused witness/reference languages entered the commitment" (Fields.fieldScriptDataHash (fields balanced) /= allViews)
    Tx.encodeCbor imported @?= bytes

datumCommitments :: IO ()
datumCommitments = do
  (configured, output, wallet) <- Fixture.fixture
  datum <- must (Data.decodeCbor (B.pack [0x18, 0x01]))
  (unusedScripts, unusedModels) <- unusedLanguages
  witnesses <- must (Witnesses.mkWitnesses [] [] unusedScripts [datum] [])
  encoded <- must (Body.fromBody (Body.body [Utxo.input wallet] [output] 0))
  let imported = Tx.assemble encoded (Witnesses.fromWitnesses witnesses) Nothing
      models = Models.fromList unusedModels
      context = configured {Builder.availableUtxos = [], Builder.parameters = (Builder.parameters configured) {Parameters.parameterCostModels = Just models}}
  balanced <- Balancing.balance context [wallet] imported >>= must
  assertCommitment Models.empty balanced
  Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses balanced)) @?= [datum]
  allViews <- Building.scriptDataHash models (Tx.witnesses balanced) >>= must
  -- Datum-only commitments have empty views even when models were supplied.
  Fields.fieldScriptDataHash (fields balanced) @?= allViews

-- A transfer consumes and produces the same token units. These opposing sides
-- each fit Int64; adding their absolute magnitudes is not a native accumulator.
maximumTokenTransfer :: IO ()
maximumTokenTransfer = do
  (configured, _, wallet) <- Fixture.fixture
  policy <- must (Policy.fromBytes (B.replicate 28 46))
  referenceId <- must (Id.fromBytes (B.replicate 32 47))
  let asset = Asset.Native policy AssetName.empty
      quantity = toInteger (maxBound :: Int64)
      address = Builder.changeAddress configured
  fundingOutput <- must (Output.mkOutput address (Value.fromList [(Asset.Ada, 10000000), (asset, quantity)]) Datum.NoDatum Nothing)
  output <- must (Output.mkOutput address (Value.fromList [(Asset.Ada, 2000000), (asset, quantity)]) Datum.NoDatum Nothing)
  referenceOutput <- must (Output.mkOutput address (Value.fromList [(Asset.Ada, 3000000), (asset, quantity)]) Datum.NoDatum Nothing)
  let fundingInput = Utxo.utxo (Utxo.input wallet) fundingOutput
      reference = Utxo.utxo (Input.input referenceId 0) referenceOutput
      -- Neither an extra resolution snapshot nor a reference input authorizes
      -- spending its tokens, so neither contributes to consumed-value bounds.
      cases = [(Nothing, [fundingInput]), (Nothing, [fundingInput, reference]), (Just [Utxo.input reference], [fundingInput, reference])]
      context = configured {Builder.availableUtxos = [], Builder.collateralUtxos = [], Builder.minimumFee = 200000, Builder.selector = Nothing}
  forM_ cases $ \(references, resolved) -> do
    let common = (Fields.fields [Utxo.input fundingInput] [output]) {Fields.fieldReferenceInputs = references}
    imported <- Tx.fromBody <$> must (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = common}))
    let before = Tx.encodeCbor imported
    balanced <- Balancing.balance context resolved imported >>= must
    Fields.fieldInputs (fields balanced) @?= [Utxo.input fundingInput]
    Fields.fieldReferenceInputs (fields balanced) @?= references
    take 1 (Fields.fieldOutputs (fields balanced)) @?= [output]
    sum [Value.quantity asset (Output.value item) | item <- Fields.fieldOutputs (fields balanced)] @?= quantity
    Body.fee (semantic balanced) @?= 200000
    Building.isBalanced (Builder.parameters context) resolved balanced >>= (@?= Right True)
    Tx.encodeCbor imported @?= before

numericBounds :: IO ()
numericBounds = do
  (configured, output, wallet) <- Fixture.fixture
  original <- Tx.fromBody <$> must (Body.fromBody (Body.body [Utxo.input wallet] [output] 0))
  huge <- funding configured 45 (2 ^ (63 :: Int) - 1)
  calls <- newIORef (0 :: Int)
  let selected = Selection.Selector $ \_ -> modifyIORef' calls (+ 1) >> pure (Left (InvalidTransactionPlan "numeric preflight must precede selection"))
      context = configured {Builder.availableUtxos = [], Builder.selector = Just selected}
      cases =
        [ (context {Builder.minimumFee = maxBound}, [wallet]),
          (context {Builder.extraSigners = maxBound}, [wallet]),
          (context {Builder.parameters = (Builder.parameters context) {Parameters.parameterAdaPerUtxoByte = Just maxBound}}, [wallet]),
          (context {Builder.availableUtxos = [huge]}, [wallet])
        ]
  forM_ cases $ \(options, resolved) ->
    Balancing.balance options resolved original >>= assertBool "numeric native-bound overflow accepted" . isLeft
  readIORef calls >>= (@?= 0)

failures :: IO ()
failures = do
  baseline <- Runtime.liveContexts
  (configured, locked, _, original) <- scriptDraft
  let expected = InvalidTransactionPlan "rebalancing callback refused draft"
      run callback = Balancing.balanceWithRedeemers configured (locked : Builder.collateralUtxos configured) (Map.singleton (Evaluation.RedeemerId Redeemer.Spending 0) callback) original
      lazyFailure _ _ = Right (Data.fromData (Data.List [Data.Integer (throw (userError "lazy rebalancing payload"))]))
  replicateM_ 3 (run (\_ _ -> Left expected) >>= (@?= Left expected))
  outcome <- try (run lazyFailure)
  case outcome of
    Left (failure :: SomeException) -> assertBool "lazy callback exception retained" ("lazy rebalancing payload" `isInfixOf` displayException failure)
    Right result -> assertFailure ("lazy callback returned normally: " <> show result)
  Runtime.liveContexts >>= (@?= baseline)

cancellation :: IO ()
cancellation = do
  baseline <- Runtime.liveContexts
  (configured, locked, _, original) <- scriptDraft
  finished <- newEmptyMVar
  cancelled <- newEmptyMVar
  let never _ _ = Right (Data.fromData (Data.Integer (sum [1 ..])))
      overrides = Map.singleton (Evaluation.RedeemerId Redeemer.Spending 0) never
  worker <- forkFinally (Balancing.balanceWithRedeemers configured (locked : Builder.collateralUtxos configured) overrides original) (putMVar finished)
  -- Match the existing deferred-construction cancellation fixture: the payload
  -- never materializes, and cancellation must unwind its joined native scope.
  threadDelay 200000
  _ <- forkFinally (killThread worker) (putMVar cancelled)
  -- Use the builder fixtures' five-second join bound: full Valgrind runs also
  -- charge callback scheduling and native finalization to this deadline.
  outcome <- timeout 5000000 ((,) <$> readMVar finished <*> readMVar cancelled)
  case outcome of
    Just (Left failure, Right ()) -> fromException failure @?= Just ThreadKilled
    Just other -> assertFailure ("cancellation returned normally or lost its exception: " <> show other)
    Nothing -> assertFailure "deferred balancing cancellation did not join within its deadline"
  Runtime.liveContexts >>= (@?= baseline)

invalidSnapshots :: IO ()
invalidSnapshots = do
  (configured, output, wallet) <- Fixture.fixture
  original <- Tx.fromBody <$> must (Body.fromBody (Body.body [Utxo.input wallet] [output] 0))
  conflictingOutput <- must (Output.mkOutput (Builder.changeAddress configured) (Value.lovelace 11000000) Datum.NoDatum Nothing)
  calls <- newIORef (0 :: Int)
  let selected = Selection.Selector $ \_ -> modifyIORef' calls (+ 1) >> pure (Left (InvalidTransactionPlan "selection must not run"))
      checked = configured {Builder.availableUtxos = [], Builder.selector = Just selected}
      conflicting = Utxo.utxo (Utxo.input wallet) conflictingOutput
  forM_ [[], [wallet, conflicting]] $ \resolved ->
    Balancing.balance checked resolved original >>= assertBool "invalid snapshot accepted" . isLeft
  Balancing.balance checked {Builder.availableUtxos = [conflicting]} [wallet] original >>= assertBool "conflicting wallet and resolved snapshots accepted" . isLeft
  readIORef calls >>= (@?= 0)

contextualInputs :: IO ()
contextualInputs = do
  (configured, output, wallet) <- Fixture.fixture
  reference <- funding configured 40 3000000
  collateral <- funding configured 41 5000000
  let body =
        (Body.body [Utxo.input wallet] [output] 0)
          { Body.bodyFields = (Fields.fields [Utxo.input wallet] [output]) {Fields.fieldReferenceInputs = Just [Utxo.input reference]},
            Body.bodyCollateral = Just [Utxo.input collateral]
          }
  imported <- Tx.fromBody <$> must (Body.fromBody body)
  forM_ [[wallet], [wallet, reference], [wallet, collateral]] $ \resolved ->
    Balancing.balance configured {Builder.availableUtxos = []} resolved imported >>= assertBool "missing contextual input accepted" . isLeft
  balanced <- Balancing.balance configured {Builder.availableUtxos = []} [wallet, reference, collateral] imported >>= must
  Fields.fieldInputs (fields balanced) @?= [Utxo.input wallet]
  Fields.fieldReferenceInputs (fields balanced) @?= Just [Utxo.input reference]
  take 1 (Fields.fieldOutputs (fields balanced)) @?= [output]

fundingAuthority :: IO ()
fundingAuthority = do
  (configured, _, wallet) <- Fixture.fixture
  eligible <- funding configured 1 1000000
  reserve <- funding configured 2 10000000
  paymentOutput <- must (Output.mkOutput (Builder.changeAddress configured) (Value.lovelace 12000000) Datum.NoDatum Nothing)
  original <- Tx.fromBody <$> must (Body.fromBody (Body.body [Utxo.input wallet] [paymentOutput] 0))
  let bytes = Tx.encodeCbor original
      -- The explicit wallet plus mandatory input holds only 11 ADA. A snapshot
      -- supplied for inspection/resolution or collateral must not fund 12 ADA.
      options = configured {Builder.availableUtxos = [eligible]}
      cases =
        [ (options, [wallet, reserve]),
          (options {Builder.collateralUtxos = [reserve]}, [wallet]),
          (options {Builder.collateralUtxos = [reserve]}, [wallet, reserve])
        ]
  forM_ cases $ \(context, resolved) -> do
    result <- Balancing.balance context resolved original
    assertBool "resolution or collateral silently expanded wallet authority" (isLeft result)
    Tx.encodeCbor original @?= bytes

selectorCandidates :: IO ()
selectorCandidates = do
  (configured, _, wallet) <- Fixture.fixture
  eligible <- funding configured 1 5000000
  reference <- funding configured 2 10000000
  collateral <- funding configured 3 5000000
  paymentOutput <- must (Output.mkOutput (Builder.changeAddress configured) (Value.lovelace 12000000) Datum.NoDatum Nothing)
  let originalFields = (Fields.fields [Utxo.input wallet] [paymentOutput]) {Fields.fieldReferenceInputs = Just [Utxo.input reference]}
      body = (Body.body [Utxo.input wallet] [paymentOutput] 0) {Body.bodyFields = originalFields}
  original <- Tx.fromBody <$> must (Body.fromBody body)
  calls <- newIORef (0 :: Int)
  let checked = Selection.Selector $ \request -> do
        modifyIORef' calls (+ 1)
        let candidates = map Utxo.input (Selection.available request)
            required = map Utxo.input (Selection.preselected request)
        assertBool "outer spending input was exposed as an additional candidate" (Utxo.input wallet `notElem` candidates)
        assertBool "outer reference input was exposed as an additional candidate" (Utxo.input reference `notElem` candidates)
        assertBool "collateral-only snapshot was exposed as an additional candidate" (Utxo.input collateral `notElem` candidates)
        assertBool "selector received an unauthorized candidate" (all (== Utxo.input eligible) candidates)
        assertBool "mandatory outer input was not preselected" (Utxo.input wallet `elem` required)
        Selection.select spendAll request
      context =
        configured
          { Builder.availableUtxos = [wallet, reference, eligible],
            Builder.collateralUtxos = [collateral],
            Builder.selector = Just checked
          }
  balanced <- Balancing.balance context [wallet, reference] original >>= must
  readIORef calls >>= assertBool "selector was not invoked" . (> 0)
  Fields.fieldInputs (fields balanced) @?= sort [Utxo.input wallet, Utxo.input eligible]
  Fields.fieldReferenceInputs (fields balanced) @?= Just [Utxo.input reference]

invalidRedeemers :: IO ()
invalidRedeemers = do
  (configured, output, wallet) <- Fixture.fixture
  imported <- Tx.fromBody <$> must (Body.fromBody (Body.body [Utxo.input wallet] [output] 0))
  let argument = Data.fromData (Data.Integer 0)
  forM_ [minBound .. maxBound] $ \purpose -> do
    let index = if purpose == Redeemer.Spending then maxBound else 0
    witnesses <- must (Witnesses.mkWitnesses [] [] [] [] [Redeemer.Redeemer purpose index argument (ExUnits 0 0)])
    let malformed = Tx.setWitnesses (Witnesses.fromWitnesses witnesses) imported
    Balancing.balance configured {Builder.availableUtxos = []} [wallet] malformed >>= assertBool "out-of-range redeemer accepted" . isLeft
  let never _ _ = throw (userError "unmatched rebalancing callback ran")
  Balancing.balanceWithRedeemers configured [wallet] (Map.singleton (Evaluation.RedeemerId Redeemer.Spending 99) never) imported >>= assertBool "unmatched callback identifier accepted" . isLeft

nested :: IO ()
nested = nestedWithEnvelope False

nestedIndefinite :: IO ()
nestedIndefinite = nestedWithEnvelope True

nestedWithEnvelope :: Bool -> IO ()
nestedWithEnvelope indefinite = do
  (configured, output, wallet) <- Fixture.fixture
  nestedInput <- funding configured 40 5000000
  reference <- funding configured 41 3000000
  message <- must (Metadata.mkText "signed nested content")
  metadata <- must (Metadata.decodeCbor (Metadata.encodeCbor (Metadata.singleton 674 message)))
  let auxiliary = Auxiliary.fromAuxiliaryData (Auxiliary.auxiliaryData (Just metadata) Nothing [])
  auxiliaryHash <- Auxiliary.hash auxiliary >>= must
  commitment <- must (Datum.hashFromBytes (Auxiliary.hashBytes auxiliaryHash))
  let subFields =
        (Fields.fields [Utxo.input nestedInput] [output])
          { Fields.fieldReferenceInputs = Just [Utxo.input reference],
            Fields.fieldAuxiliaryDataHash = Just commitment
          }
  encodedBody <- must (SubBody.fromBody (SubBody.fromFields subFields))
  let unsigned = Sub.assemble encodedBody (Witnesses.fromWitnesses Witnesses.empty) (Just auxiliary)
  signed <- SigningKey.withNormalKey (B.replicate 32 11) (`Signing.signSubTransaction` unsigned) >>= must
  let canonicalFrame = Sub.encodeCbor signed
  B.take 1 canonicalFrame @?= B.singleton 0x83
  intent <-
    if indefinite
      then must (Sub.decodeCbor (B.singleton 0x9f <> B.drop 1 canonicalFrame <> B.singleton 0xff))
      else pure signed
  let body = (Body.body [Utxo.input wallet] [output] 0) {Body.bodySubTransactions = Just [intent]}
      dijkstra = configured {Builder.availableUtxos = [], Builder.parameters = (Builder.parameters configured) {Parameters.parameterProtocolVersion = Version.ProtocolVersion 12 0}}
      originalEnvelope = Sub.encodeCbor intent
      bodyBytes = SubBody.toCbor (Sub.body intent)
      witnessBytes = Witnesses.toCbor (Sub.witnesses intent)
      auxiliaryBytes = Auxiliary.toCbor <$> Sub.auxiliaryData intent
  originalId <- Sub.transactionId intent >>= must
  imported <- Tx.fromBody <$> must (Body.fromBody body)
  Balancing.balance dijkstra [wallet, nestedInput] imported >>= assertBool "missing nested reference accepted" . isLeft
  balanced <- Balancing.balance dijkstra [wallet, nestedInput, reference] imported >>= must
  case Body.bodySubTransactions (semantic balanced) of
    Just [actual] -> do
      -- Native code may rewrite the containing three-field envelope. Exact signed
      -- body, witnesses and auxiliary data define the retained nested content.
      SubBody.toCbor (Sub.body actual) @?= bodyBytes
      Witnesses.toCbor (Sub.witnesses actual) @?= witnessBytes
      (Auxiliary.toCbor <$> Sub.auxiliaryData actual) @?= auxiliaryBytes
      Sub.transactionId actual >>= (@?= Right originalId)
      forM_ (Witnesses.verificationWitnesses (Witnesses.toWitnesses (Sub.witnesses actual))) $ \witness ->
        Key.verify (Witness.publicKey witness) (Id.toBytes originalId) (Witness.signature witness) >>= (@?= Right True)
    other -> assertFailure ("nested intent disappeared: " <> show other)
  Sub.encodeCbor intent @?= originalEnvelope
