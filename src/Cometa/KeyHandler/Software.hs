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
{-# LANGUAGE RoleAnnotations #-}

-- | Scoped encrypted software key storage. Each public-key operation requests a password
-- from the supplied action. Passwords are raw bytes (including NUL), 1 through
-- 128 bytes; no text normalization is performed. Keep application-owned inputs
-- and callback results only as long as your application requires: closing cannot
-- erase those Haskell values or copies made by the application.
--
-- A handler closes on every continuation exit, including exceptions. Escaped
-- handles reject further operations. Operations on independent handlers may run
-- concurrently; overlap and callback reentry on the same handler return
-- 'KeyHandlerBusy'. A password action must not wait for another operation on
-- its own handler. Cancellation waits for the password action and native work
-- to unwind; an action that masks cancellation can delay cleanup.
--
-- @
-- import qualified Cometa.KeyHandler.Software as Software
--
-- storeEntropy entropy encryptionPassword requestPassword =
--   Software.withEntropy entropy encryptionPassword requestPassword Software.serialize
-- @
module Cometa.KeyHandler.Software
  ( -- * Capabilities
    Handler,
    Bip32,
    Ed25519,
    LoadedHandler (..),

    -- * Scoped construction
    withEntropy,
    withSigningKey,
    withSerialized,

    -- * Operations
    close,
    accountPublicKey,
    publicKey,
    name,
    serialize,
    signTransaction,
    signTransactionAt,
    signSubTransaction,
    signSubTransactionAt,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PublicKey as Bip32Public
import Cometa.Crypto.DerivationPath (AccountPath)
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.Crypto.Ed25519.PublicKey as EdPublic
import Cometa.Crypto.Ed25519.SigningKey (SigningKey)
import Cometa.Error (Error (..))
import Cometa.Internal.Ed25519SigningKey (SigningKey (..))
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.KeyHandler as Internal
import qualified Cometa.SubTransaction as SubTransaction
import qualified Cometa.Transaction as Transaction
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad (join)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import Data.Word (Word32)
import Foreign.C.Types (CUInt)

-- TYPES ----------------------------------------------------------------------

-- | BIP32 capability: derive an account public key from encrypted entropy.
data Bip32

-- | Ed25519 capability: recover the public key associated with encrypted key bytes.
data Ed25519

-- | A scoped handler whose capability determines the available operations.
-- No equality or printable representation exposes secret storage.
type role Handler nominal

newtype Handler mode = Handler Internal.Handler

-- | The serialized format determines the handler capability. Metadata is CRC
-- protected, not authenticated; accept storage only from a trusted source.
data LoadedHandler
  = -- | A handler storing BIP39 entropy for hierarchical account derivation.
    Bip32Handler (Handler Bip32)
  | -- | A handler storing a normal or extended Ed25519 signing key.
    Ed25519Handler (Handler Ed25519)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encrypt BIP39 entropy (16, 20, 24, 28 or 32 bytes) immediately with the
-- supplied encryption password, then run the continuation. The request action
-- supplies a fresh password for each derivation. Root derivation uses the empty
-- BIP39 password; the encryption password only protects storage.
withEntropy :: ByteString -> ByteString -> IO ByteString -> (Handler Bip32 -> IO (Either Error value)) -> IO (Either Error value)
withEntropy entropy password request action
  | size `notElem` [16, 20, 24, 28, 32] = pure (Left (InvalidBip39EntropyLength size))
  | otherwise = flatten <$> Internal.withEntropy entropy password request (action . Handler)
  where
    size = ByteString.length entropy

-- | Encrypt a copy of a scoped normal or extended signing key. The source stays
-- usable independently. A closed source returns 'SigningKeyClosed'.
withSigningKey :: SigningKey -> ByteString -> IO ByteString -> (Handler Ed25519 -> IO (Either Error value)) -> IO (Either Error value)
withSigningKey (SigningKey source) password request action = flatten <$> Internal.withSigningKey source password request (action . Handler)

-- | Open the native binary storage format. Validates framing, type, canonical
-- encrypted payload sizes and checksum before invoking the continuation. It does not
-- request a password or authenticate the encrypted payload until a public-key
-- operation is requested. Wrong passwords fail that later operation.
withSerialized :: ByteString -> IO ByteString -> (LoadedHandler -> IO (Either Error value)) -> IO (Either Error value)
withSerialized bytes request action =
  flatten
    <$> Internal.withSerialized
      bytes
      request
      ( \bip32 handler ->
          action (if bip32 then Bip32Handler (Handler handler) else Ed25519Handler (Handler handler))
      )

-- | Close immediately, or return 'KeyHandlerBusy' if an operation is active.
-- Repeated close succeeds. Scope exit waits for ongoing work and closes even
-- when a prior explicit close returned busy.
close :: Handler mode -> IO (Either Error ())
close (Handler handler) = mapFailure <$> Internal.close handler

-- | Derive the account extended public key at three hardened path components.
-- The public result remains usable after this handler closes.
accountPublicKey :: Handler Bip32 -> AccountPath -> IO (Either Error Bip32Public.PublicKey)
accountPublicKey (Handler handler) path = do
  result <- Internal.accountPublicKey handler (component Path.purpose) (component Path.coinType) (component Path.account)
  pure (mapFailure result >>= Bip32Public.fromBytes)
  where
    component field = Path.indexValue (field path)

-- | Recover the Ed25519 public key. Each call requests a password, and the
-- returned immutable key remains usable after this handler closes.
publicKey :: Handler Ed25519 -> IO (Either Error EdPublic.PublicKey)
publicKey (Handler handler) = do
  result <- Internal.publicKey handler
  pure (mapFailure result >>= EdPublic.fromBytes)

-- | Implementation name for diagnostics. Does not request a password.
name :: Handler mode -> IO (Either Error Text)
name (Handler handler) = mapFailure <$> Internal.name handler

-- | Copy encrypted storage bytes for persistence; does not request a password.
-- The binary format contains encrypted key material and CRC-protected metadata.
-- The metadata is not cryptographically authenticated. The result can outlive
-- the scope; protect it against unauthorized modification and password guessing.
serialize :: Handler mode -> IO (Either Error ByteString)
serialize (Handler handler) = mapFailure <$> Internal.serialize handler

-- | Sign the exact transaction-body hash using the encrypted Ed25519 key.
-- Requests a password once and returns partial witnesses, without changing the
-- transaction. Merge with 'Transaction.addWitnesses' to retain existing signatures.
-- Closed, busy, password and native failures follow the ordinary handler contract.
signTransaction :: Handler Ed25519 -> Transaction.Transaction -> IO (Either Error Witnesses.EncodedWitnesses)
signTransaction (Handler handler) = signEncoded handler 0 [] . Transaction.encodeCbor

-- | Derive each nonempty five-level path and sign the exact body hash. Requests
-- a password once for the whole batch. Returns only the generated witnesses;
-- duplicate paths are idempotent. No transaction bytes are changed.
signTransactionAt :: Handler Bip32 -> NonEmpty Path.DerivationPath -> Transaction.Transaction -> IO (Either Error Witnesses.EncodedWitnesses)
signTransactionAt (Handler handler) paths = signEncoded handler 1 (map pathComponents (NonEmpty.toList paths)) . Transaction.encodeCbor

-- | Sign a sub-transaction's own exact body hash using the encrypted Ed25519 key.
-- The enclosing body and its signatures are independent of this operation.
signSubTransaction :: Handler Ed25519 -> SubTransaction.SubTransaction -> IO (Either Error Witnesses.EncodedWitnesses)
signSubTransaction (Handler handler) = signEncoded handler 2 [] . SubTransaction.encodeCbor

-- | Derive the supplied paths and sign this sub-transaction's own body hash.
-- Requests a password once and returns partial witnesses without changing input.
signSubTransactionAt :: Handler Bip32 -> NonEmpty Path.DerivationPath -> SubTransaction.SubTransaction -> IO (Either Error Witnesses.EncodedWitnesses)
signSubTransactionAt (Handler handler) paths = signEncoded handler 3 (map pathComponents (NonEmpty.toList paths)) . SubTransaction.encodeCbor

signEncoded :: Internal.Handler -> CUInt -> [[Word32]] -> ByteString -> IO (Either Error Witnesses.EncodedWitnesses)
signEncoded handler kind paths bytes = do
  result <- Internal.signTransaction handler kind paths bytes
  pure (mapFailure result >>= Witnesses.decodeCbor)

pathComponents :: Path.DerivationPath -> [Word32]
pathComponents path =
  let account = Path.accountPrefix path
   in map Path.indexValue [Path.purpose account, Path.coinType account, Path.account account, Path.role path, Path.index path]

flatten :: Either Internal.Failure (Either Error value) -> Either Error value
flatten = join . mapFailure

mapFailure :: Either Internal.Failure value -> Either Error value
mapFailure = either (Left . publicFailure) Right

publicFailure :: Internal.Failure -> Error
publicFailure failure = case failure of
  Internal.Closed -> KeyHandlerClosed
  Internal.Busy -> KeyHandlerBusy
  Internal.PasswordLength size -> InvalidKeyHandlerPasswordLength size
  Internal.InvalidStorage -> InvalidKeyHandlerStorage
  Internal.SourceClosed -> SigningKeyClosed
  Internal.NativeFailure native -> fromNativeFailure native
