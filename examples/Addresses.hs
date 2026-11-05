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

import qualified Cometa.Address.Shelley as Address
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Bip32 as Bip32
import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- Public deterministic fixture entropy; never fund this example wallet.
main :: IO ()
main = do
  result <- runExceptT receivingAddress
  either (die . show) Text.putStrLn result

receivingAddress :: ExceptT Error IO Text
receivingAddress = do
  let account = Path.standardAccountPath minBound
      paymentPath = Path.derivationPath account Path.externalRole minBound
      stakePath = Path.derivationPath account Path.stakingRole minBound
      entropy = ByteString.replicate 16 0

  paymentKey <- ExceptT (Bip32.derivePublicKey "" entropy paymentPath)
  stakeKey <- ExceptT (Bip32.derivePublicKey "" entropy stakePath)
  payment <- ExceptT (Credential.fromPublicKey (PublicKey.toEd25519 paymentKey))
  stake <- ExceptT (Credential.fromPublicKey (PublicKey.toEd25519 stakeKey))

  pure (Address.toText (Address.base Address.testnet payment stake))
