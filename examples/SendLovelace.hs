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
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext, required, unsigned)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "SendLovelace" payment

payment :: WalletContext -> IO (Either Error [Tx.Transaction])
payment wallet = do
  recipient <- required "COMETA_RECIPIENT"
  lovelace <- required "COMETA_LOVELACE"
  let settings = (,) <$> (recipient >>= Address.fromText) <*> (lovelace >>= unsigned)
  case settings of
    Left failure -> pure (Left failure)
    Right (destination, amount) -> runExceptT $ do
      output <- except (Output.mkOutput destination (Value.lovelace (toInteger amount)) Datum.NoDatum Nothing)
      confirmed <- ExceptT (submitPlan (Support.context wallet) (Plan.payTo output))
      pure [confirmed]

submitPlan :: Workflow.Context -> Plan.Plan -> IO (Either Error Tx.Transaction)
submitPlan ctx plan = runExceptT $ do
  settings <- ExceptT (Workflow.builderConfig ctx)
  unsignedTx <- ExceptT (Builder.build settings (plan <> Plan.validUntil (Workflow.invalidAfter ctx)))
  witnesses <- ExceptT (Signer.signTransaction (Workflow.signer ctx) unsignedTx)
  signed <- except (Tx.addWitnesses witnesses unsignedTx)
  expected <- ExceptT (Tx.transactionId signed)
  accepted <- ExceptT (Provider.submitTransaction (Workflow.provider ctx) signed)
  unless (accepted == expected) (throwE (InvalidProviderResponse "Submitted transaction ID mismatch"))
  confirmed <- ExceptT (Provider.awaitTransaction (Workflow.provider ctx) accepted (Workflow.confirmationTimeoutMillis ctx))
  unless confirmed (throwE (InvalidBuildingRequest "Transaction confirmation timed out"))
  ExceptT (Workflow.awaitWallet ctx signed)
  pure signed
