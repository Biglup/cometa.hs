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

module RewardAccountPubkey (main, rewardKey) where

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Certificate as Certificate
import Cometa.Credential (Credential (..), KeyHash, Stake, StakePool)
import Cometa.Error (Error (..))
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Plan as Plan
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import qualified Support.Inputs as Inputs
import qualified Support.Transaction as Workflow
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypointWithDescription "RewardAccountPubkey" (Inputs.describe Nothing) $ \wallet -> runExceptT $ do
  let context = Support.context wallet
  pool <- ExceptT Inputs.poolId
  ExceptT (rewardKey context (Support.stakeCredential wallet) pool)

rewardKey :: Workflow.Context -> Credential Stake -> KeyHash StakePool -> IO (Either Error [Transaction])
rewardKey ctx stake pool = runExceptT $ do
  let certify = Plan.certificate
  params <- ExceptT (Provider.protocolParameters (Workflow.provider ctx))
  let deposit = Parameters.parameterKeyDeposit params
      account = Reward.fromCredential (Workflow.network ctx) stake
      registration =
        certify (Certificate.Registration stake deposit)
          <> certify (Certificate.StakeDelegation stake pool)
          <> Plan.certificate (Certificate.VoteDelegation stake DRep.AlwaysAbstain)
  registered <- ExceptT (submitPlan ctx registration)
  rewards <- ExceptT (Provider.rewardBalance (Workflow.provider ctx) account)
  let withdrawal = Plan.withdraw account rewards
  cleaned <- ExceptT (submitPlan ctx (withdrawal <> certify (Certificate.Unregistration stake deposit)))
  pure [registered, cleaned]

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
