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

-- | Produce and attach Ed25519 transaction witnesses using scoped signing keys.
-- Signatures cover the exact transaction-body hash; witnesses and outer framing
-- never enter the signed message. Operations preserve the source transaction.
module Cometa.Transaction.Signing
  ( verificationWitness,
    sign,
    subTransactionWitness,
    signSubTransaction,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error)
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)

-- DEFINITIONS ----------------------------------------------------------------

-- | Sign the exact body hash and pair it with the key's public key. The key
-- must remain open throughout the operation. No transaction bytes are changed.
verificationWitness :: Key.SigningKey -> Tx.Transaction -> IO (Either Error Witness.VerificationWitness)
verificationWitness key transaction = witnessForHash key (Tx.transactionId transaction)

-- | Add this key's witness, retaining existing partial signatures and exact body
-- bytes. Repeating the same signature is an exact no-op; a conflicting existing
-- signature for that public key fails. Closed keys and native failures fail.
sign :: Key.SigningKey -> Tx.Transaction -> IO (Either Error Tx.Transaction)
sign key transaction = runExceptT $ do
  witness <- ExceptT (verificationWitness key transaction)
  merged <- ExceptT (pure (Witnesses.addVerificationWitness witness (Tx.witnesses transaction)))
  pure (Tx.setWitnesses merged transaction)

-- | Sign a sub-transaction's own body hash, independent of its enclosing body.
subTransactionWitness :: Key.SigningKey -> Sub.SubTransaction -> IO (Either Error Witness.VerificationWitness)
subTransactionWitness key transaction = witnessForHash key (Sub.transactionId transaction)

-- | Add a signature to this sub-transaction while preserving its exact body.
signSubTransaction :: Key.SigningKey -> Sub.SubTransaction -> IO (Either Error Sub.SubTransaction)
signSubTransaction key transaction = runExceptT $ do
  witness <- ExceptT (subTransactionWitness key transaction)
  merged <- ExceptT (pure (Witnesses.addVerificationWitness witness (Sub.witnesses transaction)))
  pure (Sub.setWitnesses merged transaction)

witnessForHash :: Key.SigningKey -> IO (Either Error TxId.TransactionId) -> IO (Either Error Witness.VerificationWitness)
witnessForHash key hashAction = runExceptT $ do
  digest <- ExceptT hashAction
  public <- ExceptT (Key.publicKey key)
  signature <- ExceptT (Key.sign key (TxId.toBytes digest))
  pure (Witness.verificationWitness public signature)
