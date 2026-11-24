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

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.Bip39 as Bip39
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.KeyHandler.Software as Software
import qualified Cometa.NetworkId as Network
-- Standard library and error handling.
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Data.Text.IO as Text
import System.Exit (die)

-- Public demonstration material. Never send funds to this address.
main :: IO ()
main = do
  let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
      entropy = Bip39.fromText phrase >>= Bip39.exportEntropy
      password = "public demonstration password"
  result <- case entropy of
    Left failure -> pure (Left failure)
    Right bytes -> Software.withEntropy bytes password (pure password) $ \handler -> runExceptT $ do
      let account = Path.standardAccountPath minBound
          paymentPath = Path.derivationPath account Path.externalRole minBound
          stakePath = Path.derivationPath account Path.stakingRole minBound
      public <- ExceptT (Software.accountPublicKey handler account)
      paymentKey <- ExceptT (Public.derive public (Path.relativeIndices paymentPath))
      stakeKey <- ExceptT (Public.derive public (Path.relativeIndices stakePath))
      payment <- ExceptT (Credential.fromPublicKey (Public.toEd25519 paymentKey))
      stake <- ExceptT (Credential.fromPublicKey (Public.toEd25519 stakeKey))
      pure (Address.ShelleyAddress (Shelley.base Network.testnet payment stake))
  either (die . show) (Text.putStrLn . Address.toText) result
