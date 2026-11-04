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

-- | Sign and verify a message using a published RFC 8032 test seed.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import System.Exit (die)

-- DEFINITIONS ---------------------------------------------------------------

main :: IO ()
main = do
  -- Published test seed. Never use it for funds or application secrets.
  let seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
      message = "Hello, Cardano!"

  result <- SigningKey.withNormalKeyHex seed $ \key -> runExceptT $ do
    public <- ExceptT (SigningKey.publicKey key)
    signature <- ExceptT (SigningKey.sign key message)
    verified <- ExceptT (PublicKey.verify public message signature)

    pure (public, signature, verified)

  case result of
    Left failure -> die (show failure)
    Right (public, signature, verified) -> do
      print (PublicKey.toHex public)
      print (Signature.toHex signature)
      print verified
