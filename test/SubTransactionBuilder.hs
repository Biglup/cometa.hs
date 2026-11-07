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

-- | Offline sub-transaction intent construction and scoped callback evidence.
module SubTransactionBuilder (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error (..))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Committee as Committee
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.SubTransactionBuilder as Internal
import qualified Cometa.Internal.SubTransactionPlan as InternalPlan
import qualified Cometa.Internal.TransactionPlan as Common
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as NativeScript
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.SubTransaction.Builder as Builder
import qualified Cometa.SubTransaction.Plan as Plan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as TopBuilder
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as TopPlan
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as Id
import qualified Cometa.UnitInterval as Interval
import qualified Cometa.Value as Value
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, throw, try)
import Control.Monad (forM_, replicateM_)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (elemIndex, isInfixOf, sort)
import Data.Maybe (isJust)
import qualified Fixtures.ProtocolParameters as Fixture
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Sub-transaction builder"
    [ testCase "intent preserves exact inputs/outputs without balancing" intent,
      testCase "actual V4 execution commits immediate and deferred arguments" scripts,
      testCase "composed script attachments preserve first identity and language failures" uniqueScripts,
      testCase "outer evaluation rejects underbudget signed intents and retains adequate bytes" attachedBudgets,
      testCase "reference scripts resolve from explicit reference inputs" references,
      testCase "guards, account operations and treasury donation survive building" dijkstraFields,
      testCase "all seven proposal constructors use protocol deposits" proposals,
      testCase "grouped voting redeemers run once per local voter" voting,
      testCase "deferred snapshots and indices are local and invoked once" localDraft,
      testCase "conflicts, invalid language and schedule errors are total" invalid,
      testCase "aggregate values and protocol result limits are checked" bounds,
      testCase "expected failures, lazy exceptions and partial parses clean up" failures,
      testCase "cancellation joins the pure deferred worker" cancellation
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

fixture :: IO (Builder.Config, Output.Output, Utxo.Utxo)
fixture = do
  raw <- must Fixture.parameters
  model <- must (Models.mkCostModel 3 (replicate 251 200))
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  previous <- must (Id.fromBytes (B.replicate 32 8))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
      params = raw {P.parameterProtocolVersion = Version.ProtocolVersion 12 0, P.parameterCostModels = Just (Models.fromList [model]), P.parameterMaxTxSize = 16384, P.parameterMaxTxExUnits = Just (ExUnits 100000000 100000000000)}
  funding <- must (Output.mkOutput destination (Value.lovelace 1) Datum.NoDatum Nothing)
  output <- must (Output.mkOutput destination (Value.lovelace 100000000) Datum.NoDatum Nothing)
  pure (Builder.Config params Slots.preview Fields.Testnet, output, Utxo.utxo (Input.input previous 0) funding)

fieldsOf :: Sub.SubTransaction -> Fields.Fields
fieldsOf = SubBody.fields . SubBody.toBody . Sub.body

redeemers :: Sub.SubTransaction -> [Redeemer.Redeemer]
redeemers = Witnesses.redeemers . Witnesses.toWitnesses . Sub.witnesses

scriptFixture :: IO (Plutus.PlutusScript, Policy.PolicyId)
scriptFixture = do
  -- Apache-2.0 cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
  -- lib/tests/uplc/native_tx_evaluator.cpp build_v4_script: lambda returning unit.
  script <- must (Plutus.fromBytes Plutus.V4 (B.pack [0x45, 1, 1, 0, 0x24, 0x99]))
  policy <- Policy.fromScriptHash <$> (Plutus.hash script >>= must)
  pure (script, policy)

intent :: IO ()
intent = do
  (config, output, input) <- fixture
  let plan = Plan.spend input <> Plan.payTo output <> Plan.validFrom 10 <> Plan.validUntil 20
  sub <- Builder.build config plan >>= must
  Fields.fieldInputs (fieldsOf sub) @?= [Utxo.input input]
  Fields.fieldOutputs (fieldsOf sub) @?= [output]
  Fields.fieldInvalidBefore (fieldsOf sub) @?= Just 10
  Fields.fieldInvalidAfter (fieldsOf sub) @?= Just 20
  Fields.fieldNetworkId (fieldsOf sub) @?= Just Fields.Testnet
  Plan.resolvedInputs plan @?= [input]
  Builder.build config (Plan.spend input <> Plan.spend input <> Plan.payTo output) >>= must >>= \same -> Fields.fieldInputs (fieldsOf same) @?= [Utxo.input input]
  Sub.decodeCbor (Sub.encodeCbor sub) @?= Right sub

scripts :: IO ()
scripts = do
  (config, _, _) <- fixture
  (script, policy) <- scriptFixture
  let argument = Data.fromData (Data.Integer 42)
      attached = Plan.attachScript (Script.Plutus script)
      immediate = attached <> attached <> Plan.mintWithRedeemer (asset policy) 1 argument
      deferred = attached <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] (\_ _ -> Right argument)
  first <- Builder.build config immediate >>= must
  second <- Builder.build config deferred >>= must
  first @?= second
  map Redeemer.argument (redeemers first) @?= [argument]
  map Redeemer.executionUnits (redeemers first) @?= [ExUnits 1000 1000]
  assertBool "script-data hash absent" (isJust (Fields.fieldScriptDataHash (fieldsOf first)))
  where
    asset policy = Asset.Native policy AssetName.empty

localDraft :: IO ()
localDraft = do
  (config, output, keyInput) <- fixture
  (script, _) <- scriptFixture
  digest <- Plutus.hash script >>= must
  previous <- must (Id.fromBytes (B.replicate 32 9))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.ScriptCredential digest))
      datum = Data.fromData (Data.Integer 7)
  locked <- must (Output.mkOutput destination (Value.lovelace 1) (Datum.InlineDatum datum) Nothing)
  let scriptInput = Utxo.utxo (Input.input previous 0) locked
      callback draft inputs = do
        let localInputs = Fields.fieldInputs (Body.bodyFields (Body.toBody (Tx.body draft)))
        if Body.fee (Body.toBody (Tx.body draft)) /= 0 || map Utxo.input inputs /= sort localInputs
          then Left (InvalidTransactionPlan "Expected local fee-zero canonical draft")
          else case elemIndex (Utxo.input scriptInput) localInputs of
            Nothing -> Left (InvalidTransactionPlan "Missing local input")
            Just index -> Right (Data.fromData (Data.Integer (toInteger index)))
      plan = Plan.spendWithDeferredRedeemer scriptInput callback Nothing <> Plan.spend keyInput <> Plan.payTo output <> Plan.attachScript (Script.Plutus script)
  count <- newIORef (0 :: Int)
  let observed operation bytes = modifyIORef' count (+ 1) >> Internal.dispatch plan operation bytes
  bytes <- Internal.runWithDispatch config observed (encoded plan) >>= must
  sub <- must (Sub.decodeCbor bytes)
  map Redeemer.argument (redeemers sub) @?= [Data.fromData (Data.Integer 1)]
  readIORef count >>= (@?= 1)

encoded :: Plan.Plan -> B.ByteString
encoded = Common.encodePlan . InternalPlan.toPlan

invalid :: IO ()
invalid = do
  (config, output, input) <- fixture
  let argument = Data.fromData (Data.Integer 1)
      one = Plan.spendWithDeferredRedeemer input (\_ _ -> Right argument) Nothing
  Builder.build config (one <> one <> Plan.payTo output) >>= assertBool "duplicate deferred input" . isLeft
  Builder.build config (Plan.validFrom 10 <> Plan.validUntil 10) >>= assertBool "empty validity" . isLeft
  Builder.build config (Plan.validUntil maxBound) >>= assertBool "time overflow" . isLeft
  (script, policy) <- scriptFixture
  old <- must (Plutus.fromBytes Plutus.V3 (Plutus.toBytes script))
  oldPolicy <- Policy.fromScriptHash <$> (Plutus.hash old >>= must)
  Builder.build config (Plan.attachScript (Script.Plutus old) <> Plan.mintWithDeferredRedeemer oldPolicy [(AssetName.empty, 1)] (\_ _ -> Right argument)) >>= assertBool "old language executed locally" . isLeft
  let grouped = Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] (\_ _ -> Right argument)
  Builder.build config (grouped <> grouped) >>= assertBool "repeated policy" . isLeft

failures :: IO ()
failures = do
  baseline <- Runtime.liveContexts
  (config, _, _) <- fixture
  (script, policy) <- scriptFixture
  let plan callback = Plan.attachScript (Script.Plutus script) <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] callback
      expected = InvalidTransactionPlan "Refused local draft"
  Builder.build config (plan (\_ _ -> Left expected)) >>= (@?= Left expected)
  let lazyFailure _ _ = Right (Data.fromData (Data.Integer (throw (userError "lazy sub payload"))))
  outcome <- try (Builder.build config (plan lazyFailure))
  case outcome of
    Left (failure :: SomeException) -> assertBool "lost lazy failure" ("lazy sub payload" `isInfixOf` displayException failure)
    Right result -> assertFailure (show result)
  replicateM_ 5 $ do
    Internal.runUnchecked config mempty (B.pack [0x81, 0x80]) >>= assertBool "malformed instruction accepted" . isLeft
    Internal.runWithDispatch config (\_ _ -> pure (Right (B.pack [0, 0]))) (encoded (plan (\_ _ -> Right (Data.fromData (Data.Integer 0))))) >>= assertBool "trailing payload accepted" . isLeft
  performGC
  Runtime.liveContexts >>= (@?= baseline)

cancellation :: IO ()
cancellation = do
  baseline <- Runtime.liveContexts
  (config, _, _) <- fixture
  (script, policy) <- scriptFixture
  entered <- newEmptyMVar
  finished <- newEmptyMVar
  let never _ _ = Right (Data.fromData (Data.Integer (sum [1 ..])))
      plan = Plan.attachScript (Script.Plutus script) <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] never
      observed operation bytes = putMVar entered () >> Internal.dispatch plan operation bytes
  worker <- forkFinally (Internal.runWithDispatch config observed (encoded plan)) (putMVar finished)
  takeMVar entered
  killThread worker
  outcome <- timeout 5000000 (takeMVar finished)
  case outcome of
    Just (Left _) -> pure ()
    _ -> assertFailure "cancelled sub-builder did not join its callback"
  Runtime.liveContexts >>= (@?= baseline)

references :: IO ()
references = do
  (config, _, input) <- fixture
  (script, policy) <- scriptFixture
  let funding = Utxo.output input
      argument = Data.fromData (Data.Integer 3)
  referenced <- must (Output.mkOutput (Output.address funding) (Output.value funding) Datum.NoDatum (Just (Script.Plutus script)))
  let reference = Utxo.utxo (Utxo.input input) referenced
      plan = Plan.referenceInput reference <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] (\_ _ -> Right argument)
  sub <- Builder.build config plan >>= must
  Fields.fieldReferenceInputs (fieldsOf sub) @?= Just [Utxo.input input]
  Fields.fieldInputs (fieldsOf sub) @?= []
  map Redeemer.argument (redeemers sub) @?= [argument]
  Plan.resolvedInputs plan @?= [reference]

accountFixture :: IO (Reward.RewardAddress, Anchor.Anchor)
accountFixture = do
  key <- must (Credential.keyHashFromBytes (B.replicate 28 5))
  url <- must (Anchor.mkUrl "https://example.com/governance")
  digest <- must (Anchor.dataHashFromBytes (B.replicate 32 6))
  pure (Reward.fromCredential Network.testnet (Credential.KeyCredential key), Anchor.Anchor url digest)

dijkstraFields :: IO ()
dijkstraFields = do
  (config, _, _) <- fixture
  (account, _) <- accountFixture
  (script, _) <- scriptFixture
  digest <- Plutus.hash script >>= must
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  let credential = Credential.KeyCredential key
      argument = Data.fromData (Data.Integer 99)
      plan =
        Plan.requireGuard credential
          <> Plan.guardWithRedeemer digest argument
          <> Plan.attachScript (Script.Plutus script)
          <> Plan.requireTopLevelGuard credential Nothing
          <> Plan.directDeposit account 2
          <> Plan.directDeposit account 3
          <> Plan.accountBalance account (Fields.BalanceRange (Just 1) (Just 9))
          <> Plan.donate 1
          <> Plan.donate 2
  sub <- Builder.build config plan >>= must
  Fields.fieldGuards (fieldsOf sub) @?= Just [credential, Credential.ScriptCredential digest]
  fmap Fields.entries (Fields.fieldRequiredTopLevelGuards (fieldsOf sub)) @?= Just [(credential, Nothing)]
  fmap Fields.entries (Fields.fieldDirectDeposits (fieldsOf sub)) @?= Just [(account, 5)]
  fmap Fields.entries (Fields.fieldAccountBalanceIntervals (fieldsOf sub)) @?= Just [(account, Fields.BalanceRange (Just 1) (Just 9))]
  Fields.fieldDonation (fieldsOf sub) @?= Just 3
  map Redeemer.purpose (redeemers sub) @?= [Redeemer.Guarding]
  map Redeemer.index (redeemers sub) @?= [1]
  map Redeemer.argument (redeemers sub) @?= [argument]

proposals :: IO ()
proposals = do
  (config, _, _) <- fixture
  (account, anchor) <- accountFixture
  (policyScript, _) <- scriptFixture
  policy <- Plutus.hash policyScript >>= must
  withdrawals <- must (Action.withdrawalsFromList [(account, 5)])
  quorum <- must (Interval.mkUnitInterval 1 2)
  let changes = Update.empty {Update.updateMinFeeA = Just 1}
      actions =
        [ Action.ParameterChange Nothing changes (Just policy),
          Action.HardForkInitiation Nothing (Version.ProtocolVersion 13 0),
          Action.TreasuryWithdrawals withdrawals (Just policy),
          Action.NoConfidence Nothing,
          Action.UpdateCommittee Nothing (Action.removalsFromList []) Committee.emptyMembers quorum,
          Action.NewConstitution Nothing (Constitution.Constitution anchor Nothing),
          Action.InfoAction
        ]
      configured = config {Builder.parameters = (Builder.parameters config) {P.parameterGovernanceActionDeposit = Just 500}}
  forM_ actions $ \action -> do
    sub <- Builder.build configured (Plan.attachScript (Script.Plutus policyScript) <> Plan.propose account action anchor) >>= must
    fmap Proposal.toList (Fields.fieldProposalProcedures (fieldsOf sub)) @?= Just [Proposal.Proposal 500 account action anchor]

voting :: IO ()
voting = do
  (config, _, _) <- fixture
  (script, _) <- scriptFixture
  digest <- Plutus.hash script >>= must
  previous <- must (Id.fromBytes (B.replicate 32 2))
  let voter = Voting.DRepVoter (Credential.ScriptCredential digest)
      choices = [(ActionId.ActionId previous 0, Voting.VotingProcedure Voting.Yes Nothing), (ActionId.ActionId previous 1, Voting.VotingProcedure Voting.Abstain Nothing)]
      argument = Data.fromData (Data.Integer 55)
      plan = Plan.attachScript (Script.Plutus script) <> Plan.voteWithDeferredRedeemer voter choices (\_ _ -> Right argument)
  count <- newIORef (0 :: Int)
  let observed operation bytes = modifyIORef' count (+ 1) >> Internal.dispatch plan operation bytes
  bytes <- Internal.runWithDispatch config observed (encoded plan) >>= must
  sub <- must (Sub.decodeCbor bytes)
  map Redeemer.purpose (redeemers sub) @?= [Redeemer.Voting]
  map Redeemer.argument (redeemers sub) @?= [argument]
  fmap Voting.toList (Fields.fieldVotingProcedures (fieldsOf sub)) @?= Just [(voter, fst choice, snd choice) | choice <- choices]
  readIORef count >>= (@?= 1)

bounds :: IO ()
bounds = do
  (config, output, _) <- fixture
  huge <- must (Output.mkOutput (Output.address output) (Value.lovelace 9223372036854775807) Datum.NoDatum Nothing)
  Builder.build config (Plan.payTo huge <> Plan.payTo huge) >>= assertBool "aggregate output overflow" . isLeft
  let withParams change = config {Builder.parameters = change (Builder.parameters config)}
  Builder.build (withParams (\params -> params {P.parameterKeyDeposit = maxBound})) mempty >>= assertBool "deposit narrowing" . isLeft
  Builder.build (withParams (\params -> params {P.parameterMaxTxSize = 0})) (Plan.payTo output) >>= assertBool "sub serialization size" . isLeft
  Builder.build (withParams (\params -> params {P.parameterMaxValueSize = Just 0})) (Plan.payTo output) >>= assertBool "output value size" . isLeft
  (script, policy) <- scriptFixture
  let mint = Plan.attachScript (Script.Plutus script) <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] (\_ _ -> Right (Data.fromData (Data.Integer 1)))
  Builder.build (withParams (\params -> params {P.parameterMaxTxExUnits = Just (ExUnits 999 1000)})) mint >>= assertBool "execution units exceed cap" . isLeft
  Builder.build (withParams (\params -> params {P.parameterMaxTxExUnits = Nothing})) mint >>= assertBool "missing execution cap" . isLeft

attachedBudgets :: IO ()
attachedBudgets = do
  (localConfig, _, input) <- fixture
  (script, policy) <- scriptFixture
  let address = Output.address (Utxo.output input)
      params =
        (Builder.parameters localConfig)
          { P.parameterMinFeeA = 0,
            P.parameterMinFeeB = 0,
            P.parameterMaxValueSize = Just 5000,
            P.parameterAdaPerUtxoByte = Just 4310,
            P.parameterCollateralPercentage = Just 150,
            P.parameterMaxCollateralInputs = Just 3
          }
      argument = Data.fromData (Data.Integer 1)
      mintIntent = Plan.attachScript (Script.Plutus script) <> Plan.mintWithRedeemer (Asset.Native policy AssetName.empty) 1 argument
  adequate <- Builder.build localConfig mintIntent >>= must
  models <- maybe (assertFailure "missing fixture cost models" >> fail "fixture") pure (P.parameterCostModels params)
  insufficient <- replaceBudget models (ExUnits 0 0) adequate
  wallet <- must (Output.mkOutput address (Value.lovelace 10000000) Datum.NoDatum Nothing)
  payment <- must (Output.mkOutput address (Value.lovelace 2000000) Datum.NoDatum Nothing)
  collateral <- must (Output.mkOutput address (Value.lovelace 5000000) Datum.NoDatum Nothing)
  collateralReference <- must (Id.fromBytes (B.replicate 32 10))
  let config =
        (TopBuilder.defaultConfig params Slots.preview address)
          { TopBuilder.availableUtxos = [Utxo.utxo (Utxo.input input) wallet],
            TopBuilder.collateralUtxos = [Utxo.utxo (Input.input collateralReference 0) collateral],
            TopBuilder.minimumFee = 200000
          }
      parent sub = TopPlan.payTo payment <> TopPlan.attachSubTransaction sub []
  signed <- Key.withNormalKey (B.replicate 32 7) $ \key -> do
    low <- Signing.signSubTransaction key insufficient
    enough <- Signing.signSubTransaction key adequate
    pure ((,) <$> low <*> enough)
  (signedLow, signedEnough) <- must signed
  TopBuilder.build config (parent signedLow) >>= (@?= Left (InvalidBuildingRequest "Attached subtransaction execution exceeds its declared budget"))
  batch <- TopBuilder.build config (parent signedEnough) >>= must
  fmap (map Sub.encodeCbor) (Body.bodySubTransactions (Body.toBody (Tx.body batch))) @?= Just [Sub.encodeCbor signedEnough]

replaceBudget :: Models.CostModels -> ExUnits -> Sub.SubTransaction -> IO Sub.SubTransaction
replaceBudget models units transaction = do
  let original = Witnesses.toWitnesses (Sub.witnesses transaction)
      updated = [value {Redeemer.executionUnits = units} | value <- Witnesses.redeemers original]
  witnesses <- must (Witnesses.mkWitnesses (Witnesses.verificationWitnesses original) (Witnesses.bootstrapWitnesses original) (Witnesses.scripts original) (Witnesses.datums original) updated)
  let encodedWitnesses = Witnesses.fromWitnesses witnesses
  commitment <- Building.scriptDataHash models encodedWitnesses >>= must
  let fields = (fieldsOf transaction) {Fields.fieldScriptDataHash = commitment}
  body <- must (SubBody.fromBody (SubBody.fromFields fields))
  pure (Sub.assemble body encodedWitnesses (Sub.auxiliaryData transaction))

uniqueScripts :: IO ()
uniqueScripts = do
  (config, output, input) <- fixture
  let nativeA = Script.Native (NativeScript.allOf [])
      nativeB = Script.Native (NativeScript.anyOf [])
      nativePlan = Plan.attachScript nativeB <> Plan.attachScript nativeA
      payment = Plan.spend input <> Plan.payTo output
  nativeSub <- Builder.build config (nativePlan <> nativePlan <> payment) >>= must
  Witnesses.scripts (Witnesses.toWitnesses (Sub.witnesses nativeSub)) @?= [nativeB, nativeA]
  first <- Script.Plutus <$> must (Plutus.decodeCbor Plutus.V4 (B.pack [0x58, 3, 1, 2, 3]))
  canonical <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V4 (B.pack [1, 2, 3]))
  distinct <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V4 (B.pack [4, 5, 6]))
  let once = Plan.attachScript first <> Plan.attachScript distinct <> payment
      repeated = Plan.attachScript first <> Plan.attachScript distinct <> Plan.attachScript canonical <> Plan.attachScript first <> payment
  encoded repeated @?= encoded once
  expected <- Builder.build config once >>= must
  actual <- Builder.build config repeated >>= must
  Sub.encodeCbor actual @?= Sub.encodeCbor expected
  length (Witnesses.scripts (Witnesses.toWitnesses (Sub.witnesses actual))) @?= 2
  -- Deduplication never turns an unsupported language into an accepted plan.
  forM_ [Plutus.V1 .. Plutus.V3] $ \version -> do
    old <- Script.Plutus <$> must (Plutus.fromBytes version (B.pack [1, 2, 3]))
    let attachment = Plan.attachScript old
    single <- Builder.build config (attachment <> payment)
    duplicate <- Builder.build config (attachment <> attachment <> payment)
    assertBool "unsupported sub-level script accepted" (isLeft single)
    duplicate @?= single
