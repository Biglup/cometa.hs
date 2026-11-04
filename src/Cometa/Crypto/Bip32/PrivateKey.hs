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

-- | Scoped Cardano Ed25519-BIP32 private keys. A key contains a 64-byte expanded
-- Ed25519 secret and a 32-byte chain code. It has no 'Show' or equality instance.
-- Handles reject operations after scope exit or explicit 'close'; escaped handles
-- do not extend usable lifetime. Exceptions and cancellation propagate after cleanup.
-- Closing cannot erase application inputs or explicitly exported copies.
--
-- @
-- import qualified Cometa.Crypto.Bip32.PrivateKey as PrivateKey
--
-- -- bytes must contain a 96-byte application key.
-- derivePublic bytes = PrivateKey.withKey bytes $ \root ->
--   PrivateKey.withDerived root [PrivateKey.harden 1852, PrivateKey.harden 1815,
--     PrivateKey.harden 0, 0, 0] PrivateKey.publicKey
-- @
module Cometa.Crypto.Bip32.PrivateKey
  ( PrivateKey,

    -- * Scoped acquisition
    withKey,
    withKeyHex,
    withEntropy,
    withClone,
    withDerived,
    withSigningKey,
    close,

    -- * Derivation indices
    harden,

    -- * Inspection
    byteLength,
    hexLength,
    publicKey,

    -- * Explicit secret export
    exportBytes,
    exportHex,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import Cometa.Crypto.Ed25519.SigningKey (SigningKey)
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Bip32PrivateKey as Internal
import qualified Cometa.Internal.Ed25519SigningKey as Signing
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.Hex as Hex
import Control.Monad (join)
import Data.Bits ((.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Data.Word (Word32)

-- TYPES ----------------------------------------------------------------------

-- | Opaque scoped 96-byte secret. Independent derived keys and clones may outlive
-- the source's usable lifetime only within their own active scopes.
newtype PrivateKey = PrivateKey Internal.Key

-- DEFINITIONS ----------------------------------------------------------------

-- | Import exactly 96 bytes and run the continuation. Only encoded length is
-- checked; invalid scalars may fail later operations. Wrong lengths return
-- 'InvalidBip32PrivateKeyLength' without invoking the continuation. Acquisition
-- and callback failures share one 'Either'; callback exceptions propagate.
withKey :: ByteString -> (PrivateKey -> IO (Either Error value)) -> IO (Either Error value)
withKey bytes action = flatten <$> Internal.withBytesKey bytes (action . PrivateKey)

-- | Import exactly 192 ASCII hexadecimal digits, accepting either case without
-- whitespace or prefix. Empty/malformed text returns 'InvalidHex'; valid hex of
-- another length returns 'InvalidBip32PrivateKeyLength'. Input text remains in
-- application memory after closure. Cleanup matches 'withKey'.
withKeyHex :: Text -> (PrivateKey -> IO (Either Error value)) -> IO (Either Error value)
withKeyHex text action = flatten <$> Internal.withHexKey text (action . PrivateKey)

-- | Derive a root from raw password bytes and BIP39 entropy bytes, respectively.
-- Entropy must contain 16, 20, 24, 28 or 32 bytes; other lengths return
-- 'InvalidBip39EntropyLength'. Password may be empty and may contain NUL bytes.
-- This uses Cardano's PBKDF2-HMAC-SHA512 with 4096 iterations and 96 output bytes,
-- followed by scalar clamping. No text normalization is performed. This accepts
-- entropy, not a mnemonic sentence or a 64-byte BIP39 seed. Inputs remain in
-- application memory; failures and cleanup match 'withKey'.
withEntropy :: ByteString -> ByteString -> (PrivateKey -> IO (Either Error value)) -> IO (Either Error value)
withEntropy password entropy action
  | ByteString.length entropy `notElem` [16, 20, 24, 28, 32] = pure (Left (InvalidBip39EntropyLength (ByteString.length entropy)))
  | otherwise = flatten <$> Internal.withEntropy password entropy (action . PrivateKey)

-- | Run the continuation with an independent copy. Closing either key does
-- not affect the other; the copy closes on every exit. Closed sources return
-- 'Bip32PrivateKeyClosed'.
withClone :: PrivateKey -> (PrivateKey -> IO (Either Error value)) -> IO (Either Error value)
withClone (PrivateKey key) action = flatten <$> Internal.withClone key (action . PrivateKey)

-- | Derive indices in order into an independent scope. All 'Word32' values are
-- accepted: @0..2^31-1@ are soft and @2^31..2^32-1@ are hardened. Use 'harden' to
-- set the high bit. An empty path makes an independent clone. The source remains
-- unchanged. Closed sources return 'Bip32PrivateKeyClosed'; operation failures
-- return 'NativeError'. The derived key closes before callback exceptions propagate.
withDerived :: PrivateKey -> [Word32] -> (PrivateKey -> IO (Either Error value)) -> IO (Either Error value)
withDerived (PrivateKey key) path action = flatten <$> Internal.withDerived key path (action . PrivateKey)

-- | Run the continuation with an independent extended Ed25519 signing key,
-- discarding the chain code. Closing the source does not close the signing key.
-- The signing key closes on every exit and rejects escaped uses. Closed sources
-- return 'Bip32PrivateKeyClosed'; failures return 'NativeError'.
withSigningKey :: PrivateKey -> (SigningKey -> IO (Either Error value)) -> IO (Either Error value)
withSigningKey (PrivateKey key) action = flatten <$> Internal.withSigningKey key (action . Signing.SigningKey)

-- | Set the high bit of an encoded index. This is idempotent: an already hardened
-- index is unchanged. For example, @harden 1852 == 2147485500@.
harden :: Word32 -> Word32
harden index = index .|. 0x80000000

-- | Close this handle, waiting for active operations. Repeated closure is harmless.
-- Scope exit also closes it; no later operation can use this handle.
close :: PrivateKey -> IO ()
close (PrivateKey key) = Internal.close key

-- | Secret byte count, always 96. Closed handles return
-- 'Bip32PrivateKeyClosed'.
byteLength :: PrivateKey -> IO (Either Error Int)
byteLength (PrivateKey key) = mapFailure <$> Internal.byteLength key

-- | Hexadecimal digit count, always 192, excluding a terminator. Closed handles
-- return 'Bip32PrivateKeyClosed'.
hexLength :: PrivateKey -> IO (Either Error Int)
hexLength key = fmap (* 2) <$> byteLength key

-- | Derive an immutable 64-byte public key and chain code, usable after this
-- secret closes. A closed handle returns 'Bip32PrivateKeyClosed'; unusable scalar
-- or other operation failures return 'NativeError' without secret diagnostics.
publicKey :: PrivateKey -> IO (Either Error PublicKey.PublicKey)
publicKey (PrivateKey key) = do
  result <- Internal.publicKeyBytes key
  pure (mapFailure result >>= PublicKey.fromBytes)

-- | Explicitly copy all 96 secret bytes into a Haskell ByteString. The result can
-- outlive this scope; closing cannot erase it or control subsequent application
-- copies. A closed handle returns 'Bip32PrivateKeyClosed'.
exportBytes :: PrivateKey -> IO (Either Error ByteString)
exportBytes (PrivateKey key) = mapFailure <$> Internal.exportBytes key

-- | Explicitly export 192 lowercase ASCII hex digits without prefix. The text
-- has application-managed lifetime and is not erased on closure. A closed handle
-- returns 'Bip32PrivateKeyClosed'.
exportHex :: PrivateKey -> IO (Either Error Text)
exportHex key = fmap Hex.encodeHex <$> exportBytes key

flatten :: Either Internal.Failure (Either Error value) -> Either Error value
flatten = join . mapFailure

mapFailure :: Either Internal.Failure value -> Either Error value
mapFailure = either (Left . publicFailure) Right

publicFailure :: Internal.Failure -> Error
publicFailure failure = case failure of
  Internal.Closed -> Bip32PrivateKeyClosed
  Internal.InvalidLength _ actual -> InvalidBip32PrivateKeyLength actual
  Internal.InvalidHex -> InvalidHex
  Internal.NativeFailure failureValue -> fromNativeFailure failureValue
