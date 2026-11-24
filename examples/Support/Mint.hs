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
module Support.Mint (nativeScript, mintBerries) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Address (Address)
import Cometa.AssetId (AssetId (Native))
import qualified Cometa.AssetName as AssetName
import Cometa.Credential (ScriptHash)
import Cometa.Error (Error)
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as NativeScript
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Text (Text)
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext (..))

-- DEFINITIONS ----------------------------------------------------------------

nativeScript :: Script.Script
nativeScript = Script.Native (NativeScript.allOf [NativeScript.invalidAfter 1001655683199])

-- The source mints two named assets with CIP-25 metadata, then burns Onyx.
-- Derive the metadata policy key from the actual script, rather than copying
-- the unrelated fixed key in the C++ example's illustrative JSON.
mintBerries :: WalletContext -> Script.Script -> Maybe Utxo.Utxo -> Text -> IO (Either Error [Tx.Transaction])
mintBerries wallet script reference prefix = runExceptT $ do
  digest <- ExceptT (Script.hash script)
  (mintPlan, burnPlan) <- except (berryPlans (Workflow.wallet (context wallet)) script reference prefix digest)
  minted <- ExceptT (Workflow.runStage (context wallet) mintPlan)
  burned <- ExceptT (Workflow.runStage (context wallet) burnPlan)
  pure [minted, burned]

berryPlans :: Address -> Script.Script -> Maybe Utxo.Utxo -> Text -> ScriptHash -> Either Error (Plan.Plan, Plan.Plan)
berryPlans recipient script reference prefix digest = do
  onyxName <- AssetName.fromText (prefix <> "BerryOnyx")
  raspberryName <- AssetName.fromText (prefix <> "BerryRaspberry")
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
