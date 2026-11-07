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
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Environment parsing shared by explicitly invoked connected examples.
module Blockfrost.Common (configuration, required, networkSlots, addressNetwork, withWallet) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error (..))
import qualified Cometa.KeyHandler.Software as Software
import Cometa.NetworkId (NetworkId)
import qualified Cometa.NetworkId as Network
import qualified Cometa.Provider.Blockfrost as Blockfrost
import qualified Cometa.Signer as Signer
import Cometa.SlotConfig (SlotConfig)
import qualified Cometa.SlotConfig as Slots
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
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
configuration = runExceptT $ do
  networkName <- ExceptT (required "COMETA_NETWORK")
  network <- except $ case networkName of
    "mainnet" -> Right Blockfrost.Mainnet
    "preprod" -> Right Blockfrost.Preprod
    "preview" -> Right Blockfrost.Preview
    _ -> Left (InvalidProviderConfiguration "COMETA_NETWORK must be mainnet, preprod or preview")
  projectText <- liftIO (lookupEnv "BLOCKFROST_PROJECT_ID")
  project <- except (traverse (Blockfrost.mkProjectId . Text.pack) projectText)
  endpoint <- liftIO (lookupEnv "BLOCKFROST_URL")
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

-- | The encrypted handler and password come from caller configuration. No
-- storage bytes or passwords are printed; all signing stays inside this scope.
withWallet :: Blockfrost.Network -> (Address.Address -> Signer.Signer -> IO (Either Error a)) -> IO (Either Error a)
withWallet network action = do
  settings <- runExceptT $ (,) <$> ExceptT (required "COMETA_KEY_HANDLER_FILE") <*> ExceptT (required "COMETA_KEY_PASSWORD")
  case settings of
    Left failure -> pure (Left failure)
    Right (file, password) -> do
      stored <- ByteString.readFile (Text.unpack file)
      Software.withSerialized stored (pure (Text.encodeUtf8 password)) $ \case
        Software.Ed25519Handler handler -> do
          result <- runExceptT $ do
            public <- ExceptT (Software.publicKey handler)
            payment <- ExceptT (Credential.fromPublicKey public)
            pure (Address.ShelleyAddress (Shelley.enterprise (addressNetwork network) payment))
          either (pure . Left) (\address -> action address (Signer.software handler)) result
        Software.Bip32Handler handler -> do
          let account = Path.standardAccountPath minBound
              paymentPath = Path.derivationPath account Path.externalRole minBound
              stakePath = Path.derivationPath account Path.stakingRole minBound
          result <- runExceptT $ do
            accountKey <- ExceptT (Software.accountPublicKey handler account)
            paymentKey <- ExceptT (Public.derive accountKey (Path.relativeIndices paymentPath))
            stakeKey <- ExceptT (Public.derive accountKey (Path.relativeIndices stakePath))
            payment <- ExceptT (Credential.fromPublicKey (Public.toEd25519 paymentKey))
            stake <- ExceptT (Credential.fromPublicKey (Public.toEd25519 stakeKey))
            pure (Address.ShelleyAddress (Shelley.base (addressNetwork network) payment stake))
          either (pure . Left) (\address -> action address (Signer.bip32 handler (paymentPath :| []))) result
