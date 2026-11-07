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

-- | Build/sign a payment; submission requires the explicit --submit argument.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Blockfrost.Common as Common
import qualified Cometa.Address as Address
import Cometa.Error (Error (..))
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost as Blockfrost
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Word (Word64)
import System.Environment (getArgs)
import System.Exit (die)
import Text.Read (readMaybe)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--build"] -> payment False
    ["--submit"] -> payment True
    _ -> putStrLn "Set the Blockfrost/payment environment described in the guide; use --build or --submit."

payment :: Bool -> IO ()
payment submit = do
  configured <- Common.configuration
  result <- case configured of
    Left failure -> pure (Left failure)
    Right config -> Blockfrost.withProvider config $ \provider ->
      Common.withWallet (Blockfrost.network config) $ \address signer -> runExceptT $ do
        recipient <- ExceptT (Common.required "COMETA_RECIPIENT") >>= except . Address.fromText
        amount <- ExceptT (Common.required "COMETA_LOVELACE") >>= except . unsigned
        upperSlot <- ExceptT (Common.required "COMETA_INVALID_AFTER_SLOT") >>= except . unsigned
        output <- except (Output.mkOutput recipient (Value.lovelace (toInteger amount)) Datum.NoDatum Nothing)
        params <- ExceptT (Provider.protocolParameters provider)
        funds <- ExceptT (Provider.utxosAt provider address)
        let settings = (Builder.defaultConfig params (Common.networkSlots (Blockfrost.network config)) address) {Builder.availableUtxos = funds}
        unsignedTx <- ExceptT (Builder.build settings (Plan.payTo output <> Plan.validUntil upperSlot))
        witnesses <- ExceptT (Signer.signTransaction signer unsignedTx)
        signed <- except (Tx.addWitnesses witnesses unsignedTx)
        identifier <- ExceptT (Tx.transactionId signed)
        if submit
          then do
            accepted <- ExceptT (Provider.submitTransaction provider signed)
            except (if accepted == identifier then Right () else Left (InvalidProviderResponse "Submitted transaction identifier differs from signed body"))
            confirmed <- ExceptT (Provider.awaitTransaction provider accepted 240000)
            pure (accepted, Just confirmed)
          else pure (identifier, Nothing)
  case result of
    Left failure -> die (show failure)
    Right (identifier, confirmed) -> do
      Text.putStrLn (Id.toHex identifier)
      putStrLn $ case confirmed of
        Nothing -> "Built and signed; no submission requested."
        Just True -> "Submitted and confirmed."
        Just False -> "Submitted; confirmation timeout elapsed."

unsigned :: Text -> Either Error Word64
unsigned text = case readMaybe (Text.unpack text) :: Maybe Integer of
  Just value | value >= 0 && value <= toInteger (maxBound :: Word64) -> Right (fromInteger value)
  _ -> Left (InvalidProviderConfiguration "Expected an unsigned 64-bit decimal amount or slot")
