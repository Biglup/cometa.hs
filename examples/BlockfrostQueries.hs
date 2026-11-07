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

-- | Connected read-only queries. Run --query explicitly; no transaction is built.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Blockfrost.Common as Common
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.AssetId as Asset
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost as Blockfrost
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.Text as Text
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--query"] -> query
    _ -> putStrLn "Set COMETA_NETWORK and COMETA_ADDRESS; optionally set BLOCKFROST_URL and BLOCKFROST_PROJECT_ID, then run with --query."

query :: IO ()
query = do
  configured <- Common.configuration
  result <- case configured of
    Left failure -> pure (Left failure)
    Right config -> Blockfrost.withProvider config $ \provider -> runExceptT $ do
      address <- ExceptT (Common.required "COMETA_ADDRESS") >>= except . Address.fromText
      params <- ExceptT (Provider.protocolParameters provider)
      outputs <- ExceptT (Provider.utxosAt provider address)
      rewardText <- ExceptT (Right <$> lookupEnv "COMETA_REWARD_ADDRESS")
      rewards <- traverse (\text -> except (Reward.fromText (Text.pack text)) >>= ExceptT . Provider.rewardBalance provider) rewardText
      pure (Parameters.parameterProtocolVersion params, length outputs, sum [Value.quantity Asset.Ada (Output.value (Utxo.output output)) | output <- outputs], rewards)
  case result of
    Left failure -> die (show failure)
    Right (version, count, lovelace, rewards) -> do
      putStrLn ("Protocol version: " <> show version)
      putStrLn ("Unspent outputs: " <> show count)
      putStrLn ("Lovelace: " <> show lovelace)
      maybe (pure ()) (\amount -> putStrLn ("Rewards: " <> show amount)) rewards
