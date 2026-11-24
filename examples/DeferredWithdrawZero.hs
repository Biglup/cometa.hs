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

module DeferredWithdrawZero (main, withdrawZero) where

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Certificate as Certificate
import Cometa.Credential (Credential (..), KeyHash, Stake, StakePool)
import Cometa.Error (Error (..))
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Provider as Provider
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import qualified Cometa.Signer as Signer
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Indices as Indices
import Cometa.Transaction.Plan (Plan)
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.List (sort)
import Data.Word (Word64)
import qualified Support.Inputs as Inputs
import qualified Support.Scripts as Scripts
import qualified Support.Transaction as Workflow
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypointWithDescription "DeferredWithdrawZero" (Inputs.describe Nothing) $ \wallet -> runExceptT $ do
  let context = Support.context wallet
  pool <- ExceptT Inputs.poolId
  ExceptT (withdrawZero context pool)

withdrawZero :: Workflow.Context -> KeyHash StakePool -> IO (Either Error [Transaction])
withdrawZero context pool = runExceptT $ do
  script <- ExceptT (fmap (fmap Script.Plutus) Scripts.withdrawZero)
  hash <- ExceptT (Script.hash script)
  deposit <- ExceptT (stakeDeposit context)
  ExceptT (runWithdrawZero context (ScriptCredential hash) script pool deposit)

stakeDeposit :: Workflow.Context -> IO (Either Error Word64)
stakeDeposit context = fmap (fmap Parameters.parameterKeyDeposit) (Provider.protocolParameters (Workflow.provider context))

runWithdrawZero :: Workflow.Context -> Credential Stake -> Script -> KeyHash StakePool -> Word64 -> IO (Either Error [Tx.Transaction])
runWithdrawZero context credential script pool deposit = runExceptT $ do
  let account = Reward.fromCredential (Workflow.network context) credential
      cert = authorize (Just script)
  registered <- ExceptT (submitPlan context (cert (Certificate.Registration credential deposit) <> cert (Certificate.StakeDelegation credential pool)))
  let callback draft inputs = do
        positions <- traverse (\input -> maybe (Left (InvalidBuildingRequest "Forwarded input disappeared")) Right (Indices.findInput (Utxo.input input) draft)) inputs
        pure (Data.fromData (Data.Constr 0 [Data.List (map (Data.Integer . toInteger) (sort positions))]))
      plan = Plan.attachScript script <> Plan.withdrawWithDeferredRedeemer account 0 callback <> cert (Certificate.Unregistration credential deposit)
  cleaned <- ExceptT (submitPlan context plan)
  pure [registered, cleaned]

authorize :: Maybe Script -> Certificate.Certificate -> Plan
authorize Nothing = Plan.certificate
authorize (Just script) = \certificate -> Plan.attachScript script <> Plan.certificateWithRedeemer certificate voidArgument

voidArgument :: Data.EncodedPlutusData
voidArgument = Data.fromData (Data.Constr 0 [])

submitPlan :: Workflow.Context -> Plan.Plan -> IO (Either Error Tx.Transaction)
submitPlan ctx plan = runExceptT $ do
  settings <- ExceptT (Workflow.builderConfig ctx)
  unsigned <- ExceptT (Builder.build settings (plan <> Plan.validUntil (Workflow.invalidAfter ctx)))
  witnesses <- ExceptT (Signer.signTransaction (Workflow.signer ctx) unsigned)
  signed <- except (Tx.addWitnesses witnesses unsigned)
  expected <- ExceptT (Tx.transactionId signed)
  accepted <- ExceptT (Provider.submitTransaction (Workflow.provider ctx) signed)
  unless (accepted == expected) (throwE (InvalidProviderResponse "Submitted transaction ID mismatch"))
  confirmed <- ExceptT (Provider.awaitTransaction (Workflow.provider ctx) accepted (Workflow.confirmationTimeoutMillis ctx))
  unless confirmed (throwE (InvalidBuildingRequest "Transaction confirmation timed out"))
  ExceptT (Workflow.awaitWallet ctx signed)
  pure signed
