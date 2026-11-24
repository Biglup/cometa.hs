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

-- | Import a recovery phrase into encrypted storage, then reopen it.
module Main (main) where

import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.Bip39 as Bip39
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error (..))
import qualified Cometa.KeyHandler.Software as Software
-- Standard library and error handling.
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as Bytes
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
-- Shared example setup.
import Support.Terminal (password, secret)
import System.Directory (doesPathExist)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--help"] -> do
      putStrLn "Usage: cabal run cometa-secure-key-handler -- WALLET_FILE"
      putStrLn "Imports a recovery phrase into a new encrypted wallet."
    [file] -> createWallet file
    _ -> die "Supply a new wallet file path; use --help for usage."

-- | Encrypt a recovery phrase into a new file, then reopen it to verify the password.
createWallet :: FilePath -> IO ()
createWallet file = do
  exists <- doesPathExist file
  when exists (die "Wallet file already exists; choose a new path.")
  phrase <- secret "Recovery phrase: "
  encryptionPassword <- password file
  repeated <- secret "Repeat password: "
  unless (encryptionPassword == Text.encodeUtf8 repeated) (die "Passwords do not match.")
  result <- runExceptT $ do
    entropy <- except (Bip39.fromText phrase >>= Bip39.exportEntropy)
    stored <- ExceptT (Software.withEntropy entropy encryptionPassword (password file) Software.serialize)
    liftIO (Bytes.writeFile file stored)
    reloaded <- liftIO (Bytes.readFile file)
    ExceptT $ Software.withSerialized reloaded (password file) $ \case
      Software.Bip32Handler handler -> fmap Public.toHex <$> Software.accountPublicKey handler (Path.standardAccountPath minBound)
      Software.Ed25519Handler _ -> pure (Left (InvalidBuildingRequest "Expected a BIP32 wallet"))
  either (die . show) (\public -> Text.putStrLn ("Account public key: " <> public)) result
