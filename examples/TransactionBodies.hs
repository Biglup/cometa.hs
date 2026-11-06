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

-- | Assemble a payment-shaped body, reload exact bytes and obtain its identifier.
-- All hashes are deterministic demonstration data; no provider or network is used.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.NetworkId as Network
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    reloaded <- except prepareBody
    transactionId <- ExceptT (Body.hash reloaded)
    pure (reloaded, transactionId)
  case result of
    Left failure -> die (show failure)
    Right (reloaded, transactionId) -> do
      putStrLn ("Transaction ID: " <> show (Id.toHex transactionId))
      putStrLn ("Fee in lovelace: " <> show (Body.fee (Body.toBody reloaded)))

prepareBody :: Either Error Body.EncodedBody
prepareBody = do
  previousId <- Id.fromBytes (ByteString.replicate 32 1)
  paymentKey <- Credential.keyHashFromBytes (ByteString.replicate 28 2)

  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential paymentKey))
      reference = Input.input previousId 0
  output <- Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing

  let minimal = Body.body [reference] [output] 170000
      validity = (Body.bodyFields minimal) {Fields.fieldInvalidBefore = Just 100, Fields.fieldInvalidAfter = Just 200}
      payment = minimal {Body.bodyFields = validity}
  encoded <- Body.fromBody payment
  Body.decodeCbor (Body.toCbor encoded)
