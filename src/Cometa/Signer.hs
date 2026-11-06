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

-- | Inject partial signing with keys kept inside scoped closures. A signer
-- returns witnesses without attaching them or submitting the transaction.
-- Merge its result explicitly with 'Cometa.Transaction.addWitnesses'.
--
-- @
-- import qualified Cometa.Signer as Signer
-- import qualified Cometa.Transaction as Tx
--
-- signWith signer transaction = do
--   result <- Signer.signTransaction signer transaction
--   pure (result >>= (\witnesses -> Tx.addWitnesses witnesses transaction))
-- @
module Cometa.Signer
  ( Signer (..),
    ed25519,
    software,
    bip32,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error)
import qualified Cometa.KeyHandler.Software as Software
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Witnesses as Witnesses
import Data.List.NonEmpty (NonEmpty)

-- TYPES ----------------------------------------------------------------------

-- | An application-supplied partial signer. Captured scoped keys/handlers must
-- remain open throughout its use; escaped closures report the existing closed
-- key/handler error. No private-key export is required.
newtype Signer = Signer
  { -- | Sign the exact transaction body, returning only additional witnesses.
    -- Expected failures use Either; exceptions retain ordinary IO behavior.
    signTransaction :: Tx.Transaction -> IO (Either Error Witnesses.EncodedWitnesses)
  }

-- DEFINITIONS ----------------------------------------------------------------

-- | Capture an open normal or extended Ed25519 signing key. The result contains
-- one Shelley verification witness and does not mutate or attach it to input.
ed25519 :: Key.SigningKey -> Signer
ed25519 key = Signer $ \transaction -> do
  result <- Signing.verificationWitness key transaction
  pure $ do
    witness <- result
    witnesses <- Witnesses.mkWitnesses [witness] [] [] [] []
    pure (Witnesses.fromWitnesses witnesses)

-- | Capture an open Ed25519 software handler, retaining its secret scope rules.
software :: Software.Handler Software.Ed25519 -> Signer
software handler = Signer (Software.signTransaction handler)

-- | Capture an open BIP32 software handler and nonempty five-level derivation
-- paths. Existing path validation and role checks are reused without key export.
bip32 :: Software.Handler Software.Bip32 -> NonEmpty Path.DerivationPath -> Signer
bip32 handler paths = Signer (Software.signTransactionAt handler paths)
