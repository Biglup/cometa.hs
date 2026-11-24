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

import Cometa.Address (Address)
import Cometa.AssetId (AssetId (Native))
import qualified Cometa.AssetName as AssetName
import Cometa.Credential (ScriptHash)
import Cometa.Error (Error (..))
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Provider as Provider
import qualified Cometa.Script as Script
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
-- Standard library and error handling.
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Text (Text)
-- Shared example setup.
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext, resolveReference)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "MintBurnPlutusScript" mintPlutus

mintPlutus :: WalletContext -> IO (Either Error [Tx.Transaction])
mintPlutus wallet = runExceptT $ do
  reference <- ExceptT (resolveReference (Support.context wallet) "COMETA_MINT_REFERENCE")
  script <- except $ case Output.referenceScript (Utxo.output reference) of
    Just value@(Script.Plutus _) -> Right value
    _ -> Left (InvalidBuildingRequest "Minting reference must carry an executable Plutus script")
  ExceptT (mintBerries wallet script (Just reference) "Plutus")

-- | Mint both named assets with CIP-25 metadata, confirm, then burn Onyx.
mintBerries ::
  WalletContext ->
  Script.Script ->
  Maybe Utxo.Utxo ->
  Text ->
  IO (Either Error [Tx.Transaction])
mintBerries wallet script reference prefix = runExceptT $ do
  digest <- ExceptT (Script.hash script)
  (mintPlan, burnPlan) <- except (berryPlans (Workflow.wallet (Support.context wallet)) script reference prefix digest)

  minted <- submitPlan (Support.context wallet) mintPlan

  burned <- submitPlan (Support.context wallet) burnPlan

  pure [minted, burned]

-- | Construct mint and burn plans using the actual policy hash in the metadata.
berryPlans ::
  Address ->
  Script.Script ->
  Maybe Utxo.Utxo ->
  Text ->
  ScriptHash ->
  Either Error (Plan.Plan, Plan.Plan)
berryPlans recipient script reference prefix digest = do
  onyxName <- AssetName.fromText (prefix <> "BerryOnyx")
  raspberryName <- AssetName.fromText (prefix <> "BerryRaspberry")

  let policy = Policy.fromScriptHash digest
      onyx = Native policy onyxName
      raspberry = Native policy raspberryName
      source = maybe (Plan.attachScript script) Plan.referenceInput reference
      mint asset amount = case script of
        Script.Native _ -> Plan.mint asset amount
        Script.Plutus _ -> Plan.mintWithRedeemer asset amount voidArgument
      text = Metadata.mkText
      pair key value = (,) <$> text key <*> text value
      record color image name = Metadata.map <$> traverse (uncurry pair) [("color", color), ("image", image), ("name", name)]
  onyxMetadata <- record "#0F0F0F" "ipfs://ipfs/QmS7w3Q5oVL9NE1gJnsMVPp6fcxia1e38cRT5pE5mmxawL" (prefix <> "Berry Onyx")
  raspberryMetadata <- record "#E30B5D" "ipfs://ipfs/QmXjegt568JqSUpAz9phxbXq5noWE3AeymZMUP43Ej2DRZ" (prefix <> "Berry Raspberry")
  policyKey <- text (Policy.toHex policy)
  onyxKey <- text (prefix <> "BerryOnyx")
  raspberryKey <- text (prefix <> "BerryRaspberry")

  let value = Value.lovelace 2000000 <> Value.fromList [(onyx, 1), (raspberry, 1)]
  output <- Output.mkOutput recipient value Datum.NoDatum Nothing

  let metadata = Metadata.map [(policyKey, Metadata.map [(onyxKey, onyxMetadata), (raspberryKey, raspberryMetadata)])]
  pure
    ( source <> mint onyx 1 <> mint raspberry 1 <> Plan.payTo output <> Plan.metadata 721 metadata,
      source <> mint onyx (-1)
    )

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
