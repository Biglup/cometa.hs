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

module DeferredRedeemerBatch (main, runDeferredBatch) where

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
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
-- Standard library and error handling.
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
-- Shared example setup.
import qualified Support.Scripts as Scripts
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "DeferredRedeemerBatch" deferredBatch

deferredBatch :: WalletContext -> IO (Either Error [Tx.Transaction])
deferredBatch wallet = runExceptT $ do
  script <- Script.Plutus <$> ExceptT Scripts.orderPairing
  ExceptT (runDeferredBatch (Support.context wallet) script)

-- | Fund two orders, then resolve their input and payout indexes during balancing.
runDeferredBatch :: Workflow.Context -> Script -> IO (Either Error [Tx.Transaction])
runDeferredBatch context script = runExceptT $ do
  (first, funded) <- ExceptT (fundInlineScript context script)
  -- Each order is funded independently; both confirmations precede settlement.
  (second, fundedAgain) <- ExceptT (fundInlineScript context script)
  firstPayout <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 1200000) Datum.NoDatum Nothing)
  secondPayout <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 1500000) Datum.NoDatum Nothing)

  let callback input minimumAmount draft _ = do
        own <- maybe (Left (InvalidBuildingRequest "Order input disappeared")) Right (Indices.findInput (Utxo.input input) draft)
        payout <-
          maybe (Left (InvalidBuildingRequest "Order payout disappeared")) Right $
            Indices.findOutput (Workflow.wallet context) minimumAmount draft
        pure (Data.fromData (Data.Constr 0 [Data.Integer (toInteger own), Data.Integer (toInteger payout)]))
      plan =
        Plan.payTo firstPayout
          <> Plan.payTo secondPayout
          <> Plan.spendWithDeferredRedeemer first (callback first 1200000) Nothing
          <> Plan.spendWithDeferredRedeemer second (callback second 1500000) Nothing
          <> Plan.attachScript script

  settled <- submitPlan context plan

  pure [funded, fundedAgain, settled]

fundInlineScript :: Workflow.Context -> Script -> IO (Either Error (Utxo, Tx.Transaction))
fundInlineScript context script = runExceptT $ do
  digest <- ExceptT (Script.hash script)

  let destination = Address.ShelleyAddress (Shelley.enterprise (Workflow.network context) (Credential.ScriptCredential digest))
  output <- except (Output.mkOutput destination (Value.lovelace 2000000) (Datum.InlineDatum voidArgument) Nothing)

  funded <- submitPlan context (Plan.payTo output)
  locked <- ExceptT (Workflow.outputAt funded 0)
  pure (locked, funded)

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
