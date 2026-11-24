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

import Cometa.Error (Error (..))
import qualified Cometa.Script as Script
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Support.Mint (mintBerries)
import Support.Wallet (WalletContext (..), resolveReference)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "MintBurnPlutusScript" mintPlutus

mintPlutus :: WalletContext -> IO (Either Error [Tx.Transaction])
mintPlutus wallet = runExceptT $ do
  reference <- ExceptT (resolveReference (context wallet) "COMETA_MINT_REFERENCE")
  script <- except $ case Output.referenceScript (Utxo.output reference) of
    Just value@(Script.Plutus _) -> Right value
    _ -> Left (InvalidBuildingRequest "Minting reference must carry an executable Plutus script")
  ExceptT (mintBerries wallet script (Just reference) "Plutus")
