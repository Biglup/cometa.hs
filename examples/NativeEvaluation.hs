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

-- | Evaluate an offline minting script and inspect its computed budget.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Evaluation.Native as Native
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    -- Single-CBOR-wrapped Flat lambda returning unit, UPLC version 1.1.0.
    script <- except (Plutus.fromBytes Plutus.V4 (ByteString.pack [0x45, 1, 1, 0, 0x24, 0x99]))
    digest <- ExceptT (Plutus.hash script)
    mint <- except (Fields.mkMint (Value.singleton (AssetId.Native (Policy.fromScriptHash digest) AssetName.empty) 1))
    let fields = (Fields.fields [] []) {Fields.fieldMint = Just mint}
        argument = Data.fromData (Data.Constr 0 [])
        redeemer = Redeemer.Redeemer Redeemer.Minting 0 argument (ExUnits 0 0)
    witnesses <- except (Witnesses.mkWitnesses [] [] [Script.Plutus script] [] [redeemer])
    body <- except (Body.fromBody (Body.body [] [] 0) {Body.bodyFields = fields})
    let transaction = Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing
        evaluator = Native.evaluator (Native.Config Slots.preview 12 Models.empty)
    -- Real applications supply chain protocol cost models and resolve every
    -- spending/reference input. This isolated mint fixture has no inputs.
    ExceptT (Evaluation.evaluate evaluator Evaluation.TopLevel transaction [])
  case result of
    Left failure -> die (show failure)
    Right budgets -> print (Evaluation.budgets budgets)
