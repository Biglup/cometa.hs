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

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.Crypto.Ed25519.PublicKey as Ed25519
import Cometa.Error (Error)
import qualified Cometa.KeyHandler.Software as Software
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- Public deterministic demonstration material only; never use it for a wallet.
main :: IO ()
main = do
  let entropy = ByteString.replicate 16 0
      password = "public demonstration password"
      requestPassword = pure password
      path = Path.standardAccountPath minBound

  result <- runExceptT $ do
    stored <- ExceptT (Software.withEntropy entropy password requestPassword Software.serialize)
    ExceptT (Software.withSerialized stored requestPassword (loadedPublicKeyHex path))

  case result of
    Left err -> die (show err)
    Right keyHex -> Text.putStrLn keyHex

-- The storage format identifies the public-key capability when reloaded.
loadedPublicKeyHex :: Path.AccountPath -> Software.LoadedHandler -> IO (Either Error Text)
loadedPublicKeyHex path loaded = case loaded of
  Software.Bip32Handler handler -> fmap Public.toHex <$> Software.accountPublicKey handler path
  Software.Ed25519Handler handler -> fmap Ed25519.toHex <$> Software.publicKey handler
