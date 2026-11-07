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

-- | Public, unfunded demonstration seed. Applications supply their own scoped key.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as Public
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error)
import qualified Cometa.Message.Cip8 as Cip8
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- Key.withNormalKey (ByteString.replicate 32 7) $ \key -> runExceptT $ do
    public <- ExceptT (Key.publicKey key)
    digest <- ExceptT (Public.hash public)
    keyHash <- except (Credential.keyHashFromBytes (Blake2b.toBytes digest) :: Either Error (Credential.KeyHash Credential.DRep))
    ExceptT (Cip8.sign key (Cip8.keyHashBinding keyHash) "Example authorization message")

  case result of
    Left failure -> die (show failure)
    Right signed -> print (ByteString.length (Cip8.coseSign1 signed), ByteString.length (Cip8.coseKey signed))
