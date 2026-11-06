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

-- | Offline native Dijkstra and governance builder workflows.
module DijkstraBuilder (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Committee as Committee
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
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
import qualified Cometa.UnitInterval as Interval
import qualified Cometa.Value as Value
import qualified Data.ByteString as B
import Data.Either (isLeft)
import qualified Fixtures.ProtocolParameters as Fixture
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Dijkstra transaction building"
    [ testCase "guards, accumulated account deposits, intervals and donation balance" accounts,
      testCase "all seven proposal actions use the protocol deposit and preserve order" proposals,
      testCase "key votes retain multiple action choices" keyVotes,
      testCase "native V4 guards and deferred grouped votes have distinct purposes" scripts,
      testCase "batch deficits and surpluses preserve subtransaction bytes" batches,
      testCase "attached scripts must fit their signed execution budgets" signedBudgets,
      testCase "conflicts, arithmetic bounds and unresolved batches fail" invalid
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

dijkstra :: IO (Builder.Config, Output.Output, Utxo.Utxo)
dijkstra = do
  (config, output, funding) <- fixture
  pure (config {Builder.parameters = (Builder.parameters config) {P.parameterProtocolVersion = Version.ProtocolVersion 12 0, P.parameterGovernanceActionDeposit = Just 100000}}, output, funding)

fields :: Tx.Transaction -> Fields.Fields
fields = Body.bodyFields . Body.toBody . Tx.body

reward :: IO Reward.RewardAddress
reward = Reward.fromCredential Network.testnet . Credential.KeyCredential <$> must (Credential.keyHashFromBytes (B.replicate 28 9))

anchor :: IO Anchor.Anchor
anchor = Anchor.Anchor <$> must (Anchor.mkUrl "https://example.com/proposal") <*> must (Anchor.dataHashFromBytes (B.replicate 32 0))

accounts :: IO ()
accounts = do
  (config, output, _) <- dijkstra
  account <- reward
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  let credential = Credential.KeyCredential key
      interval = Fields.BalanceRange (Just 1000000) (Just 5000000)
      plan =
        Plan.payTo output
          <> Plan.requireGuard credential
          <> Plan.requireGuard credential
          <> Plan.directDeposit account 1000000
          <> Plan.directDeposit account 1000000
          <> Plan.accountBalance account interval
          <> Plan.accountBalance account interval
          <> Plan.startingAccountBalance account (Fields.ExactBalance 3000000)
          <> Plan.donate 100000
          <> Plan.donate 100000
  transaction <- Builder.build config plan >>= must
  Fields.fieldGuards (fields transaction) @?= Just [credential]
  fmap Fields.entries (Fields.fieldDirectDeposits (fields transaction)) @?= Just [(account, 2000000)]
  fmap Fields.entries (Fields.fieldAccountBalanceIntervals (fields transaction)) @?= Just [(account, interval)]
  fmap Fields.entries (Body.bodyStartingAccountBalanceIntervals (Body.toBody (Tx.body transaction))) @?= Just [(account, Fields.ExactBalance 3000000)]
  Fields.fieldDonation (fields transaction) @?= Just 200000
  Value.quantity Asset.Ada (foldMap Output.value (Fields.fieldOutputs (fields transaction))) @?= 7600000

proposals :: IO ()
proposals = do
  (config, output, _) <- dijkstra
  account <- reward
  metadata <- anchor
  policyBody <- must (Plutus.fromBytes Plutus.V4 (B.pack [0x45, 1, 1, 0, 0x24, 0x99]))
  policy <- Plutus.hash policyBody >>= must
  model <- must (Models.mkCostModel 3 (replicate 369 100))
  collateralId <- must (Id.fromBytes (B.replicate 32 10))
  collateral <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 5000000) Datum.NoDatum Nothing)
  quorum <- must (Interval.mkUnitInterval 2 3)
  withdrawals <- must (Action.withdrawalsFromList [(account, 1)])
  let actions =
        [ Action.ParameterChange Nothing Update.empty (Just policy),
          Action.HardForkInitiation Nothing (Version.ProtocolVersion 12 0),
          Action.TreasuryWithdrawals withdrawals (Just policy),
          Action.NoConfidence Nothing,
          Action.UpdateCommittee Nothing (Action.removalsFromList []) Committee.emptyMembers quorum,
          Action.NewConstitution Nothing (Constitution.Constitution metadata Nothing),
          Action.InfoAction
        ]
      configured = config {Builder.parameters = (Builder.parameters config) {P.parameterCostModels = Just (Models.fromList [model])}, Builder.collateralUtxos = [Utxo.utxo (Input.input collateralId 0) collateral]}
      plan = Plan.payTo output <> Plan.attachScript (Script.Plutus policyBody) <> foldMap (\action -> Plan.propose account action metadata) actions
  transaction <- Builder.build configured plan >>= must
  fmap Proposal.toList (Fields.fieldProposalProcedures (fields transaction)) @?= Just [Proposal.Proposal 100000 account action metadata | action <- actions]
  Value.quantity Asset.Ada (foldMap Output.value (Fields.fieldOutputs (fields transaction))) @?= 9100000

keyVotes :: IO ()
keyVotes = do
  (config, output, _) <- dijkstra
  key <- must (Credential.keyHashFromBytes (B.replicate 28 5))
  identifier <- must (Id.fromBytes (B.replicate 32 3))
  let voter = Voting.DRepVoter (Credential.KeyCredential key)
      first = ActionId.ActionId identifier 0
      second = ActionId.ActionId identifier 1
      yes = Voting.VotingProcedure Voting.Yes Nothing
      no = Voting.VotingProcedure Voting.No Nothing
      plan = Plan.payTo output <> Plan.vote voter first yes <> Plan.vote voter second no <> Plan.vote voter first yes
  transaction <- Builder.build config plan >>= must
  expected <- must (Voting.fromList [(voter, first, yes), (voter, second, no)])
  Fields.fieldVotingProcedures (fields transaction) @?= Just expected
  Builder.build config (plan <> Plan.voteWithDeferredRedeemer voter [] (\_ _ -> Left (InvalidTransactionPlan "empty vote callback invoked"))) >>= (@?= Right transaction)

scripts :: IO ()
scripts = do
  baseline <- Runtime.liveContexts
  (config, output, _) <- dijkstra
  script <- must (Plutus.fromBytes Plutus.V4 (B.pack [0x45, 1, 1, 0, 0x24, 0x99]))
  hash <- Plutus.hash script >>= must
  model <- must (Models.mkCostModel 3 (replicate 369 100))
  collateralId <- must (Id.fromBytes (B.replicate 32 10))
  collateral <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 5000000) Datum.NoDatum Nothing)
  identifier <- must (Id.fromBytes (B.replicate 32 3))
  let first = ActionId.ActionId identifier 0
      second = ActionId.ActionId identifier 1
      voter = Voting.DRepVoter (Credential.ScriptCredential hash)
      yes = Voting.VotingProcedure Voting.Yes Nothing
      guardArgument = Data.fromData (Data.Integer 7)
      callback transaction _ = Right (Data.fromData (Data.Integer (toInteger (Body.fee (Body.toBody (Tx.body transaction))))))
      configured =
        config
          { Builder.parameters = (Builder.parameters config) {P.parameterCostModels = Just (Models.fromList [model]), P.parameterMaxTxExUnits = Just (ExUnits 100000000 100000000000)},
            Builder.collateralUtxos = [Utxo.utxo (Input.input collateralId 0) collateral]
          }
      plan =
        Plan.payTo output
          <> Plan.attachScript (Script.Plutus script)
          <> Plan.guardWithRedeemer hash guardArgument
          <> Plan.voteWithDeferredRedeemer voter [(first, yes), (second, yes)] callback
  transaction <- Builder.build configured plan >>= must
  let values = Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses transaction))
  map Redeemer.purpose values @?= [Redeemer.Voting, Redeemer.Guarding]
  let voteArgument = Data.fromData (Data.Integer (toInteger (Body.fee (Body.toBody (Tx.body transaction)))))
  map Redeemer.argument values @?= [voteArgument, guardArgument]
  immediate <-
    Builder.build
      configured
      (Plan.payTo output <> Plan.attachScript (Script.Plutus script) <> Plan.voteWithRedeemer voter [(first, yes), (second, yes)] guardArgument)
      >>= must
  map Redeemer.argument (Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses immediate))) @?= [guardArgument]
  let failure = InvalidTransactionPlan "voter callback refused draft"
      failed = Plan.payTo output <> Plan.attachScript (Script.Plutus script) <> Plan.voteWithDeferredRedeemer voter [(first, yes)] (\_ _ -> Left failure)
  Builder.build configured failed >>= (@?= Left failure)
  Runtime.liveContexts >>= (@?= baseline)

subFixture :: Builder.Config -> Integer -> IO (Sub.SubTransaction, Utxo.Utxo)
subFixture config amount = do
  identifier <- must (Id.fromBytes (B.replicate 32 1))
  funding <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 10000000) Datum.NoDatum Nothing)
  output <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace amount) Datum.NoDatum Nothing)
  let resolved = Utxo.utxo (Input.input identifier 0) funding
  body <- must (SubBody.fromBody (SubBody.body [Utxo.input resolved] [output]))
  pure (Sub.fromBody body, resolved)

batches :: IO ()
batches = do
  (config, output, wallet) <- dijkstra
  (deficit, input) <- subFixture config 12000000
  transaction <- Builder.build config {Builder.availableUtxos = [input, wallet]} (Plan.payTo output <> Plan.attachSubTransaction deficit [input]) >>= mustNamed "batch deficit"
  fmap (map Sub.encodeCbor) (Body.bodySubTransactions (Body.toBody (Tx.body transaction))) @?= Just [Sub.encodeCbor deficit]
  assertBool "sub input selected by parent" (Utxo.input input `notElem` Fields.fieldInputs (fields transaction))
  Value.quantity Asset.Ada (foldMap Output.value (Fields.fieldOutputs (fields transaction))) @?= 7800000
  (surplus, surplusInput) <- subFixture config 5000000
  Builder.build config {Builder.availableUtxos = []} (Plan.payTo output <> Plan.attachSubTransaction surplus [surplusInput]) >>= assertBool "default selector accepted no outer input" . isLeft
  carried <- Builder.build config (Plan.payTo output <> Plan.attachSubTransaction surplus [surplusInput]) >>= mustNamed "batch surplus"
  Fields.fieldInputs (fields carried) @?= [Utxo.input wallet]
  Value.quantity Asset.Ada (foldMap Output.value (Fields.fieldOutputs (fields carried))) @?= 14800000

invalid :: IO ()
invalid = do
  (config, output, _) <- dijkstra
  account <- reward
  identifier <- must (Id.fromBytes (B.replicate 32 3))
  key <- must (Credential.keyHashFromBytes (B.replicate 28 5))
  (sub, input) <- subFixture config 5000000
  overflowBody <- must (SubBody.fromBody (SubBody.fromFields (SubBody.fields (SubBody.toBody (Sub.body sub))) {Fields.fieldInvalidAfter = Just maxBound}))
  let overflowSub = Sub.fromBody overflowBody
  let tooSmall = config {Builder.parameters = (Builder.parameters config) {P.parameterMaxValueSize = Just 4}}
  Builder.build tooSmall (Plan.attachSubTransaction sub [input]) >>= (@?= Left (InvalidBuildingRequest "Attached subtransaction output exceeds maximum value size"))
  let voter = Voting.DRepVoter (Credential.KeyCredential key)
      action = ActionId.ActionId identifier 0
      yes = Voting.VotingProcedure Voting.Yes Nothing
      no = Voting.VotingProcedure Voting.No Nothing
      plans =
        [ Plan.directDeposit account 0,
          Plan.directDeposit account maxBound,
          Plan.directDeposit account (2 ^ (62 :: Int)) <> Plan.directDeposit account (2 ^ (62 :: Int)),
          Plan.donate maxBound,
          Plan.accountBalance account (Fields.ExactBalance 1) <> Plan.accountBalance account (Fields.ExactBalance 2),
          Plan.startingAccountBalance account (Fields.ExactBalance 1) <> Plan.startingAccountBalance account (Fields.ExactBalance 2),
          Plan.vote voter action yes <> Plan.vote voter action no,
          Plan.attachSubTransaction sub [],
          Plan.attachSubTransaction overflowSub [input],
          Plan.attachSubTransaction sub [input] <> Plan.spend input,
          Plan.attachSubTransaction sub [input] <> Plan.attachSubTransaction sub [input]
        ]
  mapM_ (\plan -> Builder.build config (Plan.payTo output <> plan) >>= assertBool "invalid plan accepted" . isLeft) plans

mustNamed :: (Show error) => String -> Either error value -> IO value
mustNamed context = either (\failure -> assertFailure (context <> ": " <> show failure) >> fail "fixture") pure

signedBudgets :: IO ()
signedBudgets = do
  (config, output, _) <- dijkstra
  (plain, input) <- subFixture config 10000000
  script <- must (Plutus.fromBytes Plutus.V4 (B.pack [0x45, 1, 1, 0, 0x24, 0x99]))
  hash <- Plutus.hash script >>= must
  model <- must (Models.mkCostModel 3 (replicate 369 100))
  collateralId <- must (Id.fromBytes (B.replicate 32 10))
  collateral <- must (Output.mkOutput (Builder.changeAddress config) (Value.lovelace 20000000) Datum.NoDatum Nothing)
  body <- must (SubBody.fromBody (SubBody.fromFields (SubBody.fields (SubBody.toBody (Sub.body plain))) {Fields.fieldGuards = Just [Credential.ScriptCredential hash]}))
  let argument = Data.fromData (Data.Constr 0 [])
      configured =
        config
          { Builder.parameters = (Builder.parameters config) {P.parameterCostModels = Just (Models.fromList [model])},
            Builder.collateralUtxos = [Utxo.utxo (Input.input collateralId 0) collateral]
          }
      intent units = do
        witnesses <- must (Witnesses.mkWitnesses [] [] [Script.Plutus script] [] [Redeemer.Redeemer Redeemer.Guarding 0 argument units])
        pure (Sub.assemble body (Witnesses.fromWitnesses witnesses) Nothing)
  underbudget <- intent (ExUnits 0 0)
  Builder.build configured (Plan.payTo output <> Plan.attachSubTransaction underbudget [input])
    >>= (@?= Left (InvalidBuildingRequest "Attached subtransaction execution exceeds its declared budget"))
  sufficient <- intent (ExUnits 1000000 1000000)
  transaction <- Builder.build configured (Plan.payTo output <> Plan.attachSubTransaction sufficient [input]) >>= must
  fmap (map Sub.encodeCbor) (Body.bodySubTransactions (Body.toBody (Tx.body transaction))) @?= Just [Sub.encodeCbor sufficient]
