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

-- | Offline selection with deterministic demonstration parameters and UTxOs.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.CoinSelection as Selection
import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.NetworkId as Network
import Cometa.Protocol.Parameters (Parameters)
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map
import qualified Fixtures.ProtocolParameters as Fixture
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    parameters <- except Fixture.parameters
    ExceptT (demonstration parameters)
  case result of
    Left failure -> die (show failure)
    Right selection -> do
      putStrLn ("Selected inputs: " <> show (length (Selection.selected selection)))
      putStrLn ("Change: " <> show (map Output.value (Selection.change selection)))

demonstration :: Parameters -> IO (Either Error Selection.Selection)
demonstration parameters = runExceptT $ do
  payment <- except (Credential.keyHashFromBytes (B.replicate 28 7))
  previous <- except (Id.fromBytes (B.replicate 32 8))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential payment))
      resolved index amount = do
        output <- Output.mkOutput destination (Value.lovelace amount) Datum.NoDatum Nothing
        pure (Utxo.utxo (Input.input previous index) output)
  mandatory <- except (resolved 0 3000000)
  candidate <- except (resolved 1 7000000)
  request <- except (Selection.mkSelectionRequest (Selection.SelectionOptions [mandatory] [candidate] (Value.lovelace 6000000) Nothing destination parameters))
  ExceptT (Selection.select spendAll request)

-- This demonstration policy chooses every eligible input. A wallet can inject
-- a different policy through the same record without changing caller assembly.
spendAll :: Selection.Selector
spendAll = Selection.Selector $ \request -> pure $ do
  let eligible = Selection.preselected request ++ Selection.available request
      chosen = Map.elems (Map.fromList [(Utxo.input input, input) | input <- eligible])
      total = foldMap (Output.value . Utxo.output) chosen
      excess = Value.difference total (Selection.target request)
  change <-
    if Value.isZero excess
      then pure []
      else do
        output <- Output.mkOutput (Selection.changeAddress request) excess Datum.NoDatum Nothing
        pure [output]
  pure (Selection.Selection chosen [] change)
