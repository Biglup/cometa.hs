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

module PlutusV4GuardedSubTransaction (main, runGuardedSub, runSignedBatch) where

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Provider as Provider
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import qualified Cometa.Signer as Signer
import Cometa.SubTransaction (SubTransaction)
import qualified Cometa.SubTransaction.Builder as SubBuilder
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Plan (Plan)
import qualified Cometa.Transaction.Plan as Plan
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Word (Word64)
import qualified Support.Scripts as Scripts
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "PlutusV4GuardedSubTransaction" guardedSub

guardedSub :: WalletContext -> IO (Either Error [Tx.Transaction])
guardedSub wallet = runExceptT $ do
  params <- ExceptT (Provider.protocolParameters (Workflow.provider (Support.context wallet)))
  let Version.ProtocolVersion major _ = Parameters.parameterProtocolVersion params
  unless (major >= 12) (throwE (InvalidBuildingRequest "Guarded subtransactions require protocol 12 or later"))
  validator <- Script.Plutus <$> ExceptT Scripts.v4Validator
  guard <- Script.Plutus <$> ExceptT Scripts.v4Guard
  ExceptT (runGuardedSub (Support.context wallet) validator guard (Support.signSubTransaction wallet))

runGuardedSub :: Workflow.Context -> Script -> Script -> (SubTransaction -> IO (Either Error SubTransaction)) -> IO (Either Error [Tx.Transaction])
runGuardedSub context validator guard signLocal = runExceptT $ do
  (locked, reference, funded) <- ExceptT (fundScript context validator 10000000)
  params <- ExceptT (Provider.protocolParameters (Workflow.provider context))
  digest <- ExceptT (Script.hash guard)
  output <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 2000000) Datum.NoDatum Nothing)
  let source = maybe (SubPlan.attachScript validator) SubPlan.referenceInput reference
      plan =
        SubPlan.spendWith locked (Just voidArgument) Nothing
          <> SubPlan.payTo output
          <> source
          <> SubPlan.attachScript guard
          <> SubPlan.guardWithRedeemer digest voidArgument
      bodyNetwork = if Workflow.network context == Network.mainnet then Fields.Mainnet else Fields.Testnet
  local <- ExceptT (SubBuilder.build (SubBuilder.Config params (Workflow.slots context) bodyNetwork) plan)
  signed <- ExceptT (signLocal local)
  batch <- ExceptT (runSignedBatch context [(signed, SubPlan.resolvedInputs plan)] mempty)
  pure [funded, batch]

fundScript :: Workflow.Context -> Script -> Word64 -> IO (Either Error (Utxo, Maybe Utxo, Tx.Transaction))
fundScript context script amount = runExceptT $ do
  digest <- ExceptT (Script.hash script)
  let destination = Address.ShelleyAddress (Shelley.enterprise (Workflow.network context) (Credential.ScriptCredential digest))
      datum = case script of Script.Native _ -> Datum.NoDatum; Script.Plutus _ -> Datum.InlineDatum voidArgument
  output <- except (Output.mkOutput destination (Value.lovelace (toInteger amount)) datum Nothing)
  reference <- case script of
    Script.Native _ -> pure Nothing
    Script.Plutus _ -> Just <$> except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 30000000) Datum.NoDatum (Just script))
  funded <- ExceptT (submitPlan context (Plan.payTo output <> maybe mempty Plan.payTo reference))
  locked <- ExceptT (Workflow.outputAt funded 0)
  referenceUtxo <- traverse (const (ExceptT (Workflow.outputAt funded 1))) reference
  pure (locked, referenceUtxo, funded)

runSignedBatch :: Workflow.Context -> [(SubTransaction, [Utxo])] -> Plan -> IO (Either Error Tx.Transaction)
runSignedBatch context intents parent = submitPlan context (foldMap (uncurry Plan.attachSubTransaction) intents <> parent)

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
