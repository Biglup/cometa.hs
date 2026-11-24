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

module Main (main) where

import qualified Cometa.Address as Address
import Cometa.Error (Error (..))
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
-- Standard library and error handling.
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
-- Shared example setup.
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext, required, unsigned)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "SendLovelace" (runExceptT . payment)

-- | Read a payment, then build, sign, submit and confirm it with the open wallet.
payment :: WalletContext -> ExceptT Error IO Tx.Transaction
payment wallet = do
  output <- readPaymentOutput

  submitPlan (Support.context wallet) (Plan.payTo output)

-- | Validate the recipient and integer lovelace amount before building a plan.
readPaymentOutput :: ExceptT Error IO Output.Output
readPaymentOutput = do
  recipient <- ExceptT (required "COMETA_RECIPIENT")
  amount <- ExceptT (required "COMETA_LOVELACE")

  except $ do
    destination <- Address.fromText recipient
    lovelace <- unsigned amount
    Output.mkOutput destination (Value.lovelace (toInteger lovelace)) Datum.NoDatum Nothing

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
