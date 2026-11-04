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
import qualified Cometa.KeyHandler.Software as Software
import qualified Data.ByteString as ByteString
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- Public deterministic demonstration material only; never use it for a wallet.
main :: IO ()
main = case Path.mkIndex 0 of
  Left err -> die (show err)
  Right account -> do
    let path = Path.mkStandardAccountPath account
        requestPassword = pure "public demonstration password"

    result <- Software.withEntropy (ByteString.replicate 16 0) "public demonstration password" requestPassword $ \handler ->
      Software.accountPublicKey handler path

    case result of
      Left err -> die (show err)
      Right key -> Text.putStrLn (Public.toHex key)
