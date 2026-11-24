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

-- | Generic transaction recipes used by provider/FFI regression fixtures.
module Fixtures.TransactionWorkflows
  ( Context (..),
    builderConfig,
    awaitWallet,
    buildTransaction,
    signTransaction,
    submitAndConfirm,
    runStage,
    runStageWithIndexPolling,
    runPayment,
    runMintBurn,
    runLockSpend,
    runDeferredSelf,
    runDeferredBatch,
    runRewardCycle,
    runWithdrawZero,
    runDRepCycle,
    runVoteCycle,
    runDonation,
    runTreasuryWithdrawal,
    runGuardedSub,
    runSignedBatch,
    voidArgument,
  )
where

import Cometa.Address (Address)
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import Cometa.AssetId (AssetId (Native))
import Cometa.AssetName (AssetName)
import qualified Cometa.Certificate as Certificate
import Cometa.Credential (Credential, DRep, KeyHash, Stake, StakePool)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Governance.Action as Action
import Cometa.Governance.ActionId (ActionId)
import Cometa.Governance.Anchor (Anchor)
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Provider as Provider
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import qualified Cometa.Signer as Signer
import Cometa.SubTransaction (SubTransaction)
import qualified Cometa.SubTransaction.Builder as SubBuilder
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Indices as Indices
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Plan (Plan)
import qualified Cometa.Transaction.Plan as Plan
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Int (Int64)
import Data.List (sort)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Support.Transaction (Context (..), awaitWallet, builderConfig, outputAt)

voidArgument :: Data.EncodedPlutusData
voidArgument = Data.fromData (Data.Constr 0 [])

runStage :: Context -> Plan -> IO (Either Error Tx.Transaction)
runStage = runStageWithIndexPolling getMonotonicTimeNSec (threadDelay 1000000)

runStageWithIndexPolling :: IO Word64 -> IO () -> Context -> Plan -> IO (Either Error Tx.Transaction)
runStageWithIndexPolling clock pause context plan = runExceptT $ do
  liftIO (putStrLn "Building transaction...")
  unsigned <- ExceptT (buildTransaction context plan)
  liftIO (putStrLn "Signing with the encrypted wallet...")
  signed <- ExceptT (signTransaction context unsigned)
  liftIO (putStrLn "Submitting and waiting for confirmation...")
  ExceptT (submitWithIndexPolling clock pause context signed)

buildTransaction :: Context -> Plan -> IO (Either Error Tx.Transaction)
buildTransaction context plan = runExceptT $ do
  settings <- ExceptT (builderConfig context)
  ExceptT (Builder.build settings (plan <> Plan.validUntil (invalidAfter context)))

signTransaction :: Context -> Tx.Transaction -> IO (Either Error Tx.Transaction)
signTransaction context unsigned = runExceptT $ do
  witnesses <- ExceptT (Signer.signTransaction (signer context) unsigned)
  except (Tx.addWitnesses witnesses unsigned)

submitAndConfirm :: Context -> Tx.Transaction -> IO (Either Error Tx.Transaction)
submitAndConfirm = submitWithIndexPolling getMonotonicTimeNSec (threadDelay 1000000)

submitWithIndexPolling :: IO Word64 -> IO () -> Context -> Tx.Transaction -> IO (Either Error Tx.Transaction)
submitWithIndexPolling clock pause context signed = runExceptT $ do
  let backend = provider context
  identifier <- ExceptT (Tx.transactionId signed)
  accepted <- ExceptT (Provider.submitTransaction backend signed)
  unless (accepted == identifier) (throwE (InvalidProviderResponse "Submitted ID differs from signed transaction body"))
  confirmed <- ExceptT (Provider.awaitTransaction backend accepted (confirmationTimeoutMillis context))
  unless confirmed (throwE (InvalidBuildingRequest "Confirmation timed out; dependent workflow stages were not run"))
  ExceptT (awaitWalletSnapshot clock pause context signed)
  pure signed

awaitWalletSnapshot :: IO Word64 -> IO () -> Context -> Tx.Transaction -> IO (Either Error ())
awaitWalletSnapshot clock pause context transaction = runExceptT $ do
  identifier <- ExceptT (Tx.transactionId transaction)
  let fields = Body.bodyFields (Body.toBody (Tx.body transaction))
      expected = [Utxo.utxo (Input.input identifier index) output | (index, output) <- zip [0 ..] (Fields.fieldOutputs fields), Output.address output == wallet context]
      consumed = Fields.fieldInputs fields
  started <- liftIO clock
  let deadline = toInteger started + toInteger (confirmationTimeoutMillis context) * 1000000
      poll = runExceptT $ do
        current <- ExceptT (Provider.utxosAt (provider context) (wallet context))
        if all (`elem` current) expected && all ((`notElem` consumed) . Utxo.input) current
          then pure ()
          else do
            now <- liftIO clock
            if toInteger now >= deadline
              then throwE (InvalidBuildingRequest "Confirmed transaction is not yet reflected in the wallet index; dependent stages stopped")
              else liftIO pause >> ExceptT poll
  ExceptT poll

runPayment :: Context -> Address -> Word64 -> IO (Either Error Tx.Transaction)
runPayment context recipient amount = runExceptT $ do
  output <- except (Output.mkOutput recipient (Value.lovelace (toInteger amount)) Datum.NoDatum Nothing)
  ExceptT (runStage context (Plan.payTo output))

runMintBurn :: Context -> Script -> Maybe Utxo -> AssetName -> Int64 -> IO (Either Error [Tx.Transaction])
runMintBurn context script reference name amount
  | amount <= 0 = pure (Left (InvalidBuildingRequest "Mint quantity must be positive"))
  | otherwise = runExceptT $ do
      digest <- ExceptT (Script.hash script)
      let asset = Native (Policy.fromScriptHash digest) name
          operation quantity =
            maybe (Plan.attachScript script) Plan.referenceInput reference <> case script of
              Script.Native _ -> Plan.mint asset quantity
              Script.Plutus _ -> Plan.mintWithRedeemer asset quantity voidArgument
      minted <- ExceptT (runStage context (operation amount))
      burned <- ExceptT (runStage context (operation (negate amount)))
      pure [minted, burned]

runLockSpend :: Context -> Script -> Word64 -> IO (Either Error [Tx.Transaction])
runLockSpend context script amount = runExceptT $ do
  (locked, reference, funded) <- ExceptT (fundScript context script amount)
  let argument = case script of Script.Native _ -> Nothing; Script.Plutus _ -> Just voidArgument
      source = maybe (Plan.attachScript script) Plan.referenceInput reference
  payout <- except (Output.mkOutput (wallet context) (Value.lovelace 1000000) Datum.NoDatum Nothing)
  spent <- ExceptT (runStage context (Plan.payTo payout <> Plan.spendWith locked argument Nothing <> source))
  pure [funded, spent]

fundScript :: Context -> Script -> Word64 -> IO (Either Error (Utxo, Maybe Utxo, Tx.Transaction))
fundScript context = fundScriptPreserving context []

fundScriptPreserving :: Context -> [Utxo] -> Script -> Word64 -> IO (Either Error (Utxo, Maybe Utxo, Tx.Transaction))
fundScriptPreserving context protected script amount = runExceptT $ do
  digest <- ExceptT (Script.hash script)
  let destination = Address.ShelleyAddress (Shelley.enterprise (network context) (Credential.ScriptCredential digest))
      datum = case script of Script.Native _ -> Datum.NoDatum; Script.Plutus _ -> Datum.InlineDatum voidArgument
  output <- except (Output.mkOutput destination (Value.lovelace (toInteger amount)) datum Nothing)
  reference <- case script of
    Script.Native _ -> pure Nothing
    Script.Plutus _ -> Just <$> except (Output.mkOutput (wallet context) (Value.lovelace 30000000) Datum.NoDatum (Just script))
  funded <- ExceptT (runStage context (Plan.payTo output <> maybe mempty Plan.payTo reference <> foldMap Plan.referenceInput protected))
  locked <- ExceptT (outputAt funded 0)
  referenceUtxo <- traverse (const (ExceptT (outputAt funded 1))) reference
  pure (locked, referenceUtxo, funded)

fundInlineScript :: Context -> Script -> IO (Either Error (Utxo, Tx.Transaction))
fundInlineScript context script = runExceptT $ do
  digest <- ExceptT (Script.hash script)
  let destination = Address.ShelleyAddress (Shelley.enterprise (network context) (Credential.ScriptCredential digest))
  output <- except (Output.mkOutput destination (Value.lovelace 2000000) (Datum.InlineDatum voidArgument) Nothing)
  funded <- ExceptT (runStage context (Plan.payTo output))
  locked <- ExceptT (outputAt funded 0)
  pure (locked, funded)

runDeferredSelf :: Context -> Script -> IO (Either Error [Tx.Transaction])
runDeferredSelf context script = runExceptT $ do
  (locked, funded) <- ExceptT (fundInlineScript context script)
  payout <- except (Output.mkOutput (wallet context) (Value.lovelace 1000000) Datum.NoDatum Nothing)
  let callback draft _ = do
        position <- maybe (Left (InvalidBuildingRequest "Deferred input disappeared")) Right (Indices.findInput (Utxo.input locked) draft)
        pure (Data.fromData (Data.Constr 0 [Data.Integer (toInteger position)]))
      plan = Plan.payTo payout <> Plan.spendWithDeferredRedeemer locked callback Nothing <> Plan.attachScript script
  spent <- ExceptT (runStage context plan)
  pure [funded, spent]

runDeferredBatch :: Context -> Script -> IO (Either Error [Tx.Transaction])
runDeferredBatch context script = runExceptT $ do
  (first, funded) <- ExceptT (fundInlineScript context script)
  -- Each order is funded independently; both confirmations precede settlement.
  (second, fundedAgain) <- ExceptT (fundInlineScript context script)
  firstPayout <- except (Output.mkOutput (wallet context) (Value.lovelace 1200000) Datum.NoDatum Nothing)
  secondPayout <- except (Output.mkOutput (wallet context) (Value.lovelace 1500000) Datum.NoDatum Nothing)
  let callback input minimumAmount draft _ = do
        own <- maybe (Left (InvalidBuildingRequest "Order input disappeared")) Right (Indices.findInput (Utxo.input input) draft)
        payout <- maybe (Left (InvalidBuildingRequest "Order payout disappeared")) Right (Indices.findOutput (wallet context) minimumAmount draft)
        pure (Data.fromData (Data.Constr 0 [Data.Integer (toInteger own), Data.Integer (toInteger payout)]))
      plan =
        Plan.payTo firstPayout
          <> Plan.payTo secondPayout
          <> Plan.spendWithDeferredRedeemer first (callback first 1200000) Nothing
          <> Plan.spendWithDeferredRedeemer second (callback second 1500000) Nothing
          <> Plan.attachScript script
  settled <- ExceptT (runStage context plan)
  pure [funded, fundedAgain, settled]

runRewardCycle :: Context -> Credential Stake -> Maybe Script -> KeyHash StakePool -> Word64 -> IO (Either Error [Tx.Transaction])
runRewardCycle context credential script pool deposit = runExceptT $ do
  let account = Reward.fromCredential (network context) credential
      cert = authorize script
      voting = case script of
        Nothing -> cert (Certificate.VoteDelegation credential DRep.AlwaysAbstain)
        Just _ -> mempty
      register =
        cert (Certificate.Registration credential deposit)
          <> cert (Certificate.StakeDelegation credential pool)
          <> voting
  registered <- ExceptT (runStage context register)
  rewards <- ExceptT (Provider.rewardBalance (provider context) account)
  let withdrawal = case script of
        Nothing -> Plan.withdraw account rewards
        Just value -> Plan.attachScript value <> Plan.withdrawWithRedeemer account rewards voidArgument
  cleaned <- ExceptT (runStage context (withdrawal <> cert (Certificate.Unregistration credential deposit)))
  pure [registered, cleaned]

runWithdrawZero :: Context -> Credential Stake -> Script -> KeyHash StakePool -> Word64 -> IO (Either Error [Tx.Transaction])
runWithdrawZero context credential script pool deposit = runExceptT $ do
  let account = Reward.fromCredential (network context) credential
      cert = authorize (Just script)
  registered <- ExceptT (runStage context (cert (Certificate.Registration credential deposit) <> cert (Certificate.StakeDelegation credential pool)))
  let callback draft inputs = do
        positions <- traverse (\input -> maybe (Left (InvalidBuildingRequest "Forwarded input disappeared")) Right (Indices.findInput (Utxo.input input) draft)) inputs
        pure (Data.fromData (Data.Constr 0 [Data.List (map (Data.Integer . toInteger) (sort positions))]))
      plan = Plan.attachScript script <> Plan.withdrawWithDeferredRedeemer account 0 callback <> cert (Certificate.Unregistration credential deposit)
  cleaned <- ExceptT (runStage context plan)
  pure [registered, cleaned]

authorize :: Maybe Script -> Certificate.Certificate -> Plan
authorize Nothing = Plan.certificate
authorize (Just script) = \certificate -> Plan.attachScript script <> Plan.certificateWithRedeemer certificate voidArgument

runDRepCycle :: Context -> Credential DRep -> Maybe Script -> Word64 -> Credential Stake -> Word64 -> Anchor -> IO (Either Error [Tx.Transaction])
runDRepCycle context credential script deposit stake stakeDeposit anchor = runExceptT $ do
  registered <- ExceptT (runStage context (authorize script (Certificate.RegisterDRep credential deposit (Just anchor))))
  delegated <- ExceptT (runStage context (Plan.certificate (Certificate.Registration stake stakeDeposit) <> Plan.certificate (Certificate.VoteDelegation stake (DRep.DRepCredential credential))))
  let account = Reward.fromCredential (network context) stake
  rewards <- ExceptT (Provider.rewardBalance (provider context) account)
  cleanedStake <- ExceptT (runStage context (Plan.withdraw account rewards <> Plan.certificate (Certificate.Unregistration stake stakeDeposit)))
  cleanedDRep <- ExceptT (runStage context (authorize script (Certificate.UnregisterDRep credential deposit)))
  pure [registered, delegated, cleanedStake, cleanedDRep]

runVoteCycle :: Context -> Credential DRep -> Maybe Script -> Word64 -> Anchor -> ActionId -> IO (Either Error [Tx.Transaction])
runVoteCycle context credential script deposit anchor action = runExceptT $ do
  registered <- ExceptT (runStage context (authorize script (Certificate.RegisterDRep credential deposit (Just anchor))))
  let voter = Voting.DRepVoter credential
      procedure = Voting.VotingProcedure Voting.Yes Nothing
      vote = case script of
        Nothing -> Plan.vote voter action procedure
        Just value -> Plan.attachScript value <> Plan.voteWithRedeemer voter [(action, procedure)] voidArgument
  voted <- ExceptT (runStage context vote)
  cleaned <- ExceptT (runStage context (authorize script (Certificate.UnregisterDRep credential deposit)))
  pure [registered, voted, cleaned]

runDonation :: Context -> Word64 -> IO (Either Error Tx.Transaction)
runDonation context amount = runStage context (Plan.donate amount)

runTreasuryWithdrawal :: Context -> Reward.RewardAddress -> Word64 -> Script -> Anchor -> IO (Either Error Tx.Transaction)
runTreasuryWithdrawal context account amount policy anchor = runExceptT $ do
  digest <- ExceptT (Script.hash policy)
  withdrawals <- except (Action.withdrawalsFromList [(account, amount)])
  ExceptT (runStage context (Plan.attachScript policy <> Plan.propose account (Action.TreasuryWithdrawals withdrawals (Just digest)) anchor))

runSignedBatch :: Context -> [(SubTransaction, [Utxo])] -> Plan -> IO (Either Error Tx.Transaction)
runSignedBatch context intents parent = runStage context (foldMap (uncurry Plan.attachSubTransaction) intents <> parent)

runGuardedSub :: Context -> Script -> Script -> (SubTransaction -> IO (Either Error SubTransaction)) -> IO (Either Error [Tx.Transaction])
runGuardedSub context validator guard signLocal = runExceptT $ do
  (locked, reference, funded) <- ExceptT (fundScript context validator 10000000)
  params <- ExceptT (Provider.protocolParameters (provider context))
  digest <- ExceptT (Script.hash guard)
  output <- except (Output.mkOutput (wallet context) (Value.lovelace 2000000) Datum.NoDatum Nothing)
  let source = maybe (SubPlan.attachScript validator) SubPlan.referenceInput reference
      plan =
        SubPlan.spendWith locked (Just voidArgument) Nothing
          <> SubPlan.payTo output
          <> source
          <> SubPlan.attachScript guard
          <> SubPlan.guardWithRedeemer digest voidArgument
      bodyNetwork = if network context == Network.mainnet then Fields.Mainnet else Fields.Testnet
  local <- ExceptT (SubBuilder.build (SubBuilder.Config params (slots context) bodyNetwork) plan)
  signed <- ExceptT (signLocal local)
  batch <- ExceptT (runSignedBatch context [(signed, SubPlan.resolvedInputs plan)] mempty)
  pure [funded, batch]
