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

-- | An external consumer: public imports, deterministic inputs and no network.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Shelley as Address
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
import qualified Cometa.Provider.Blockfrost as Blockfrost
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Inspection as Inspection
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Aeson (Value, object, (.=))
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  digest <- Blake2b.compute 32 "abc" >>= either (die . show) pure
  unless
    (Blake2b.toHex digest == "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
    (die "BLAKE2b digest mismatch")

  -- Public RFC 8032 test seed; never use it for funds or application secrets.
  result <- SigningKey.withNormalKeyHex "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" $ \key -> runExceptT $ do
    public <- ExceptT (SigningKey.publicKey key)
    signature <- ExceptT (SigningKey.sign key "package consumer")
    verified <- ExceptT (PublicKey.verify public "package consumer" signature)
    payment <- ExceptT (Credential.fromPublicKey public)
    let address = Address.enterprise Address.testnet payment
    pure (verified, address)

  (verified, address) <- either (die . show) pure result
  unless verified (die "Ed25519 signature verification failed")
  unless
    ( Address.fromBytes (Address.toBytes address) == Right address
        && Address.fromText (Address.toText address) == Right address
    )
    (die "Address roundtrip failed")

  encodedBody <- either (die . show) pure (Body.fromBody (Body.body [] [] 42))
  let transaction = Tx.fromBody encodedBody
  unless
    (Tx.decodeCbor (Tx.encodeCbor transaction) == Right transaction)
    (die "Transaction roundtrip failed")
  identifier <- Tx.transactionId transaction >>= either (die . show) pure
  bodyIdentifier <- Body.hash encodedBody >>= either (die . show) pure
  unless (identifier == bodyIdentifier) (die "Transaction identifier mismatch")
  inspected <- Inspection.body encodedBody >>= either (die . show) pure
  unless
    (inspected == object ["inputs" .= ([] :: [Value]), "outputs" .= ([] :: [Value]), "fee" .= ("42" :: String)])
    (die "Native body inspection mismatch")

  -- Compile the included Blockfrost provider without acquiring an HTTP transport.
  let config = Blockfrost.defaultConfig Blockfrost.Preview Nothing
  config `seq` putStrLn "Source-package consumer passed (hash, signing, address, transaction, inspection, Blockfrost import)"
