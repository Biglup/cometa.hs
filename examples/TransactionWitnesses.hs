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

-- | Assemble script witnesses and auxiliary metadata through one error boundary.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as PlutusData
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    (witnesses, auxiliary) <- except prepare
    digest <- ExceptT (Auxiliary.hash auxiliary)
    pure (witnesses, digest)
  case result of
    Left failure -> die (show failure)
    Right (witnesses, digest) -> do
      putStrLn ("Redeemers: " <> show (length (Witnesses.redeemers (Witnesses.toWitnesses witnesses))))
      putStrLn ("Auxiliary-data hash: " <> show (Auxiliary.hashBytes digest))

prepare :: Either Error (Witnesses.EncodedWitnesses, Auxiliary.EncodedAuxiliaryData)
prepare = do
  message <- Metadata.mkText "offline script transaction"
  let metadata = Metadata.singleton 674 (Metadata.list [message])
      argument = PlutusData.fromData (PlutusData.Constr 0 [])
      -- Budgets are supplied by evaluation for a real transaction.
      redeemer = Redeemer.Redeemer Redeemer.Spending 0 argument (ExUnits 1000000 100000000)
      script = Script.Native (Native.allOf [])
  witnesses <- Witnesses.mkWitnesses [] [] [script] [argument] [redeemer]
  encodedMetadata <- Metadata.decodeCbor (Metadata.encodeCbor metadata)
  let auxiliary = Auxiliary.fromAuxiliaryData (Auxiliary.auxiliaryData (Just encodedMetadata) Nothing [])
  reloaded <- Witnesses.decodeCbor (Witnesses.encodeCbor witnesses)
  pure (reloaded, auxiliary)
