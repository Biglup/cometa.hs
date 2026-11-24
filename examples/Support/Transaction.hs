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

-- | Wallet/provider setup and address-index synchronization for the examples.
module Support.Transaction (Context (..), builderConfig, awaitWallet, outputAt) where

import Cometa.Address (Address)
import Cometa.Error (Error (..))
import Cometa.NetworkId (NetworkId)
import qualified Cometa.Provider as Provider
import Cometa.Signer (Signer)
import Cometa.SlotConfig (SlotConfig)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Fields as Fields
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.List (sort)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)

data Context = Context
  { provider :: Provider.Provider,
    wallet :: Address,
    signer :: Signer,
    network :: NetworkId,
    slots :: SlotConfig,
    invalidAfter :: Word64,
    collateral :: [Input],
    extraSigners :: Word64,
    confirmationTimeoutMillis :: Word64
  }

builderConfig :: Context -> IO (Either Error Builder.Config)
builderConfig context = runExceptT $ do
  let backend = provider context
  params <- ExceptT (Provider.protocolParameters backend)
  funds <- ExceptT (Provider.utxosAt backend (wallet context))
  reserved <- ExceptT (Provider.resolveInputs backend (collateral context))
  unless (sort (map Utxo.input reserved) == sort (collateral context)) (throwE (InvalidBuildingRequest "Every configured collateral input must resolve exactly once"))
  let settings =
        (Builder.defaultConfig params (slots context) (wallet context))
          { Builder.availableUtxos = filter (\value -> Utxo.input value `notElem` collateral context) funds,
            Builder.collateralUtxos = reserved,
            Builder.extraSigners = extraSigners context
          }
  pure settings

awaitWallet :: Context -> Tx.Transaction -> IO (Either Error ())
awaitWallet = awaitWalletSnapshot getMonotonicTimeNSec (threadDelay 1000000)

awaitWalletSnapshot :: IO Word64 -> IO () -> Context -> Tx.Transaction -> IO (Either Error ())
awaitWalletSnapshot clock pause context transaction = runExceptT $ do
  identifier <- ExceptT (Tx.transactionId transaction)
  let fields = Body.bodyFields (Body.toBody (Tx.body transaction))
      expected = [Utxo.utxo (Input.input identifier index) output | (index, output) <- zip [0 ..] (Fields.fieldOutputs fields), Output.address output == wallet context]
      consumed = Fields.fieldInputs fields
  started <- liftIO clock
  let deadline = toInteger started + toInteger (confirmationTimeoutMillis context) * 1000000
      poll = runExceptT $ do
        current <- ExceptT (Provider.utxosAt (provider context) (wallet context))
        if all (`elem` current) expected && all ((`notElem` consumed) . Utxo.input) current
          then pure ()
          else do
            now <- liftIO clock
            if toInteger now >= deadline
              then throwE (InvalidBuildingRequest "Confirmed transaction is not yet reflected in the wallet index; dependent stages stopped")
              else liftIO pause >> ExceptT poll
  ExceptT poll

outputAt :: Tx.Transaction -> Word64 -> IO (Either Error Utxo)
outputAt transaction index = runExceptT $ do
  identifier <- ExceptT (Tx.transactionId transaction)
  let outputs = Fields.fieldOutputs (Body.bodyFields (Body.toBody (Tx.body transaction)))
  output <- except (at index outputs)
  pure (Utxo.utxo (Input.input identifier index) output)
  where
    at 0 (value : _) = Right value
    at n (_ : rest) = at (n - 1) rest
    at _ [] = Left (InvalidBuildingRequest "Workflow output index is absent")
