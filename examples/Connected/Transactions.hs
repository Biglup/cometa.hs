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

-- | Connected payment, mint/burn, script-spending and deferred-index recipes.
module Connected.Transactions (payment, mintNative, mintPlutus, spendNative, spendPlutus, deferredSelf, deferredBatch, guardedSub) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (Native))
import qualified Cometa.AssetName as AssetName
import Cometa.Error (Error (..))
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Provider as Provider
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as NativeScript
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Connected.Support (WalletContext (..), required, resolveReference, unsigned)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Text (Text)
import qualified Workflows.Native as Workflow
import qualified Workflows.NativeScripts as Scripts

-- DEFINITIONS ----------------------------------------------------------------

payment :: WalletContext -> IO (Either Error [Tx.Transaction])
payment wallet = runExceptT $ do
  destination <- ExceptT (required "COMETA_RECIPIENT") >>= except . Address.fromText
  amount <- ExceptT (required "COMETA_LOVELACE") >>= except . unsigned
  transaction <- ExceptT (Workflow.runPayment (context wallet) destination amount)
  pure [transaction]

nativeScript :: Script.Script
nativeScript = Script.Native (NativeScript.allOf [NativeScript.invalidAfter 1001655683199])

mintNative :: WalletContext -> IO (Either Error [Tx.Transaction])
mintNative wallet = mintBerries wallet nativeScript Nothing ""

mintPlutus :: WalletContext -> IO (Either Error [Tx.Transaction])
mintPlutus wallet = runExceptT $ do
  reference <- ExceptT (resolveReference (context wallet) "COMETA_MINT_REFERENCE")
  script <- except $ case Output.referenceScript (Utxo.output reference) of
    Just value@(Script.Plutus _) -> Right value
    _ -> Left (InvalidBuildingRequest "Minting reference must carry an executable Plutus script")
  ExceptT (mintBerries wallet script (Just reference) "Plutus")

-- The source mints two named assets with CIP-25 metadata, then burns Onyx.
-- Derive the metadata policy key from the actual script, rather than copying
-- the unrelated fixed key in the C++ example's illustrative JSON.
mintBerries :: WalletContext -> Script.Script -> Maybe Utxo.Utxo -> Text -> IO (Either Error [Tx.Transaction])
mintBerries wallet script reference prefix = runExceptT $ do
  digest <- ExceptT (Script.hash script)
  onyxName <- except (AssetName.fromText (prefix <> "BerryOnyx"))
  raspberryName <- except (AssetName.fromText (prefix <> "BerryRaspberry"))
  let policy = Policy.fromScriptHash digest
      onyx = Native policy onyxName
      raspberry = Native policy raspberryName
      source = maybe (Plan.attachScript script) Plan.referenceInput reference
      mint asset amount = case script of
        Script.Native _ -> Plan.mint asset amount
        Script.Plutus _ -> Plan.mintWithRedeemer asset amount Workflow.voidArgument
      text = Metadata.mkText
      pair key value = (,) <$> text key <*> text value
      record color image name = Metadata.map <$> traverse (uncurry pair) [("color", color), ("image", image), ("name", name)]
  onyxMetadata <- except (record "#0F0F0F" "ipfs://ipfs/QmS7w3Q5oVL9NE1gJnsMVPp6fcxia1e38cRT5pE5mmxawL" (prefix <> "Berry Onyx"))
  raspberryMetadata <- except (record "#E30B5D" "ipfs://ipfs/QmXjegt568JqSUpAz9phxbXq5noWE3AeymZMUP43Ej2DRZ" (prefix <> "Berry Raspberry"))
  policyKey <- except (text (Policy.toHex policy))
  onyxKey <- except (text (prefix <> "BerryOnyx"))
  raspberryKey <- except (text (prefix <> "BerryRaspberry"))
  let value = Value.lovelace 2000000 <> Value.fromList [(onyx, 1), (raspberry, 1)]
  output <- except (Output.mkOutput (Workflow.wallet (context wallet)) value Datum.NoDatum Nothing)
  let metadata = Metadata.map [(policyKey, Metadata.map [(onyxKey, onyxMetadata), (raspberryKey, raspberryMetadata)])]
  minted <- ExceptT (Workflow.runStage (context wallet) (source <> mint onyx 1 <> mint raspberry 1 <> Plan.payTo output <> Plan.metadata 721 metadata))
  burned <- ExceptT (Workflow.runStage (context wallet) (source <> mint onyx (-1)))
  pure [minted, burned]

spendNative :: WalletContext -> IO (Either Error [Tx.Transaction])
spendNative wallet = Workflow.runLockSpend (context wallet) nativeScript 2000000

spendPlutus :: WalletContext -> IO (Either Error [Tx.Transaction])
spendPlutus wallet = runExceptT $ do
  script <- Script.Plutus <$> ExceptT Scripts.alwaysSucceedsV3
  ExceptT (Workflow.runLockSpend (context wallet) script 2000000)

deferredSelf :: WalletContext -> IO (Either Error [Tx.Transaction])
deferredSelf wallet = runExceptT $ do
  script <- Script.Plutus <$> ExceptT Scripts.selfIndex
  ExceptT (Workflow.runDeferredSelf (context wallet) script)

deferredBatch :: WalletContext -> IO (Either Error [Tx.Transaction])
deferredBatch wallet = runExceptT $ do
  script <- Script.Plutus <$> ExceptT Scripts.orderPairing
  ExceptT (Workflow.runDeferredBatch (context wallet) script)

-- | Dijkstra is not active on every network. Check the current protocol before
-- any funding submission so running this entrypoint on Conway leaves no locks.
guardedSub :: WalletContext -> IO (Either Error [Tx.Transaction])
guardedSub wallet = runExceptT $ do
  params <- ExceptT (Provider.protocolParameters (Workflow.provider (context wallet)))
  let Version.ProtocolVersion major _ = Parameters.parameterProtocolVersion params
  except (if major >= 12 then Right () else Left (InvalidBuildingRequest "Guarded subtransactions require an active Dijkstra network (protocol 12 or later); use the offline example on Conway"))
  validator <- Script.Plutus <$> ExceptT Scripts.v4Validator
  guard <- Script.Plutus <$> ExceptT Scripts.v4Guard
  ExceptT (Workflow.runGuardedSub (context wallet) validator guard (signSubTransaction wallet))
