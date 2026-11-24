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
import qualified Cometa.TransactionId as Id
-- Standard library and error handling.
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.List (sort)
import Data.Word (Word64)
-- Shared example setup.
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

-- | Register and delegate, then withdraw zero with final input indexes and deregister.
runWithdrawZero ::
  Workflow.Context ->
  Credential Stake ->
  Script ->
  KeyHash StakePool ->
  Word64 ->
  IO (Either Error [Tx.Transaction])
runWithdrawZero context credential script pool deposit = runExceptT $ do
  let account = Reward.fromCredential (Workflow.network context) credential
      cert = authorize (Just script)

  registered <- submitPlan context (cert (Certificate.Registration credential deposit) <> cert (Certificate.StakeDelegation credential pool))

  let callback draft inputs = do
        let position input =
              maybe (Left (InvalidBuildingRequest "Forwarded input disappeared")) Right $
                Indices.findInput (Utxo.input input) draft

        positions <- traverse position inputs
        pure (Data.fromData (Data.Constr 0 [Data.List (map (Data.Integer . toInteger) (sort positions))]))
      plan = Plan.attachScript script <> Plan.withdrawWithDeferredRedeemer account 0 callback <> cert (Certificate.Unregistration credential deposit)

  cleaned <- submitPlan context plan

  pure [registered, cleaned]

authorize :: Maybe Script -> Certificate.Certificate -> Plan
authorize Nothing = Plan.certificate
authorize (Just script) = \certificate -> Plan.attachScript script <> Plan.certificateWithRedeemer certificate voidArgument

voidArgument :: Data.EncodedPlutusData
voidArgument = Data.fromData (Data.Constr 0 [])

-- | Run one stage; dependent stages start only after confirmation and indexing.
submitPlan :: Workflow.Context -> Plan.Plan -> ExceptT Error IO Tx.Transaction
submitPlan ctx plan = do
  unsignedTx <- buildTransaction ctx plan
  signedTx <- signTransaction ctx unsignedTx

  txId <- submitTransaction ctx signedTx
  awaitConfirmation ctx signedTx txId

  pure signedTx

-- | Fetch current wallet inputs and parameters, then apply the configured expiry.
buildTransaction :: Workflow.Context -> Plan.Plan -> ExceptT Error IO Tx.Transaction
buildTransaction ctx plan = do
  settings <- ExceptT (Workflow.builderConfig ctx)
  ExceptT $
    Builder.build settings (plan <> Plan.validUntil (Workflow.invalidAfter ctx))

-- | The scoped wallet requests its password and supplies the required witnesses.
signTransaction :: Workflow.Context -> Tx.Transaction -> ExceptT Error IO Tx.Transaction
signTransaction ctx unsignedTx = do
  witnesses <-
    ExceptT (Signer.signTransaction (Workflow.signer ctx) unsignedTx)
  except (Tx.addWitnesses witnesses unsignedTx)

-- | Submit once and verify the provider accepted this exact transaction body.
submitTransaction :: Workflow.Context -> Tx.Transaction -> ExceptT Error IO Id.TransactionId
submitTransaction ctx signedTx = do
  expected <- ExceptT (Tx.transactionId signedTx)
  accepted <- ExceptT (Provider.submitTransaction (Workflow.provider ctx) signedTx)

  unless (accepted == expected) $
    throwE (InvalidProviderResponse "Submitted transaction ID mismatch")

  pure accepted

-- | Stop on timeout; wait for the wallet index before spending dependent outputs.
awaitConfirmation :: Workflow.Context -> Tx.Transaction -> Id.TransactionId -> ExceptT Error IO ()
awaitConfirmation ctx signedTx txId = do
  confirmed <-
    ExceptT $
      Provider.awaitTransaction
        (Workflow.provider ctx)
        txId
        (Workflow.confirmationTimeoutMillis ctx)

  unless confirmed $
    throwE (InvalidBuildingRequest "Transaction confirmation timed out")

  ExceptT (Workflow.awaitWallet ctx signedTx)
