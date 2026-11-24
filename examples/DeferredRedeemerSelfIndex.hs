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

module DeferredRedeemerSelfIndex (main, runDeferredSelf) where

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.PlutusData as Data
import qualified Cometa.Provider as Provider
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Indices as Indices
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import qualified Support.Scripts as Scripts
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "DeferredRedeemerSelfIndex" deferredSelf

deferredSelf :: WalletContext -> IO (Either Error [Tx.Transaction])
deferredSelf wallet = runExceptT $ do
  script <- Script.Plutus <$> ExceptT Scripts.selfIndex
  ExceptT (runDeferredSelf (Support.context wallet) script)

runDeferredSelf :: Workflow.Context -> Script -> IO (Either Error [Tx.Transaction])
runDeferredSelf context script = runExceptT $ do
  (locked, funded) <- ExceptT (fundInlineScript context script)
  payout <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 1000000) Datum.NoDatum Nothing)
  let callback draft _ = do
        position <- maybe (Left (InvalidBuildingRequest "Deferred input disappeared")) Right (Indices.findInput (Utxo.input locked) draft)
        pure (Data.fromData (Data.Constr 0 [Data.Integer (toInteger position)]))
      plan = Plan.payTo payout <> Plan.spendWithDeferredRedeemer locked callback Nothing <> Plan.attachScript script
  spent <- ExceptT (submitPlan context plan)
  pure [funded, spent]

fundInlineScript :: Workflow.Context -> Script -> IO (Either Error (Utxo, Tx.Transaction))
fundInlineScript context script = runExceptT $ do
  digest <- ExceptT (Script.hash script)
  let destination = Address.ShelleyAddress (Shelley.enterprise (Workflow.network context) (Credential.ScriptCredential digest))
  output <- except (Output.mkOutput destination (Value.lovelace 2000000) (Datum.InlineDatum voidArgument) Nothing)
  funded <- ExceptT (submitPlan context (Plan.payTo output))
  locked <- ExceptT (Workflow.outputAt funded 0)
  pure (locked, funded)

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
