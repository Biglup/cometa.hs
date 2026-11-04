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

import qualified Cometa.Crypto.Bip32.PrivateKey as PrivateKey
import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import qualified Cometa.Crypto.Bip39 as Bip39
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- Public deterministic test phrase; never use this wallet for funds.
testPhrase :: Text
testPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

main :: IO ()
main = do
  result <- runExceptT $ do
    mnemonic <- except (Bip39.fromText testPhrase)
    entropy <- except (Bip39.exportEntropy mnemonic)
    ExceptT (PrivateKey.withEntropy ByteString.empty entropy PrivateKey.publicKey)

  either (die . show) (Text.putStrLn . PublicKey.toHex) result
