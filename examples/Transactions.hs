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

-- | Reload and inspect a transaction, then add a signature without changing its ID.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.TransactionId as TxId
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- signStoredTransaction
  case result of
    Left failure -> die (show failure)
    Right (signed, digest) -> do
      putStrLn ("Transaction ID: " <> show (TxId.toHex digest))
      putStrLn ("Fee in lovelace: " <> show (Body.fee (Body.toBody (Tx.body signed))))
      putStrLn ("Signed transaction bytes: " <> show (ByteString.length (Tx.encodeCbor signed)))

signStoredTransaction :: IO (Either Error (Tx.Transaction, TxId.TransactionId))
signStoredTransaction = runExceptT $ do
  -- Deterministic test data only. Empty input/output lists illustrate storage
  -- and signing; this transaction is not balanced or valid for submission.
  let stored = ByteString.pack [0x84, 0xa3, 0, 0x80, 1, 0x80, 2, 10, 0xa0, 0xf5, 0xf6]
      seed = ByteString.replicate 32 42

  transaction <- except (Tx.decodeCbor stored)
  signed <- ExceptT (Key.withNormalKey seed (`Signing.sign` transaction))
  digest <- ExceptT (Tx.transactionId signed)
  pure (signed, digest)
