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

-- | Environment parsing shared by explicitly invoked connected examples.
module Support.Configuration (configuration, required, networkSlots, addressNetwork) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.NetworkId (NetworkId)
import qualified Cometa.NetworkId as Network
import qualified Cometa.Provider.Blockfrost as Blockfrost
import Cometa.SlotConfig (SlotConfig)
import qualified Cometa.SlotConfig as Slots
-- Standard library and error handling.
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (lookupEnv)

-- DEFINITIONS ----------------------------------------------------------------

required :: String -> IO (Either Error Text)
required name = do
  value <- lookupEnv name
  pure $ case value of
    Nothing -> Left (InvalidProviderConfiguration ("Missing environment variable: " <> Text.pack name))
    Just "" -> Left (InvalidProviderConfiguration ("Empty environment variable: " <> Text.pack name))
    Just text -> Right (Text.pack text)

configuration :: IO (Either Error Blockfrost.Config)
configuration = do
  networkName <- required "COMETA_NETWORK"
  projectText <- lookupEnv "BLOCKFROST_PROJECT_ID"
  endpoint <- lookupEnv "BLOCKFROST_URL"
  pure $ do
    name <- networkName
    network <- case name of
      "mainnet" -> Right Blockfrost.Mainnet
      "preprod" -> Right Blockfrost.Preprod
      "preview" -> Right Blockfrost.Preview
      _ -> Left (InvalidProviderConfiguration "COMETA_NETWORK must be mainnet, preprod or preview")
    project <- traverse (Blockfrost.mkProjectId . Text.pack) projectText

    let defaults = Blockfrost.defaultConfig network project
    pure (maybe defaults (\url -> defaults {Blockfrost.endpoint = Text.pack url}) endpoint)

networkSlots :: Blockfrost.Network -> SlotConfig
networkSlots network = case network of
  Blockfrost.Mainnet -> Slots.mainnet
  Blockfrost.Preprod -> Slots.preprod
  Blockfrost.Preview -> Slots.preview

addressNetwork :: Blockfrost.Network -> NetworkId
addressNetwork network = case network of
  Blockfrost.Mainnet -> Network.mainnet
  Blockfrost.Preprod -> Network.testnet
  Blockfrost.Preview -> Network.testnet
