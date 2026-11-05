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

import qualified Cometa.Crypto.Bip32 as Bip32
import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Data.ByteString as ByteString
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  -- Deterministic test entropy; never use this key for funds.
  let entropy = ByteString.replicate 16 0
      account = Path.standardAccountPath minBound
      payment = Path.derivationPath account Path.externalRole minBound

  result <- Bip32.derivePublicKey "" entropy payment

  case result of
    Left failure -> die (show failure)
    Right public -> Text.putStrLn (PublicKey.toHex public)
