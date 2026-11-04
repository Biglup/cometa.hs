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

-- | Scoped Ed25519 signing keys. Normal keys contain a 32-byte seed; extended
-- keys contain a 64-byte expanded scalar and nonce prefix, rather than a seed/public-key
-- pair. Keys have no printable or equality representation.
--
-- The continuation receives a key valid until its scope exits. Keeping the
-- handle afterward is possible, but all subsequent operations return
-- 'SigningKeyClosed'. Scope exit and 'close' wait for ongoing operations.
-- Callback exceptions, including cancellation, propagate after cleanup.
--
-- Closing a key ends access through its handle. It does not erase the input
-- bytes or text supplied by the application, or any explicitly exported copies.
--
-- @
-- import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
--
-- -- seed must contain exactly 32 bytes obtained from the application.
-- signMessage seed message =
--   SigningKey.withNormalKey seed $ \key -> SigningKey.sign key message
-- @
module Cometa.Crypto.Ed25519.SigningKey
  ( SigningKey,

    -- * Scoped import and copying
    withNormalKey,
    withExtendedKey,
    withNormalKeyHex,
    withExtendedKeyHex,
    withClone,
    close,

    -- * Inspection and signing
    byteLength,
    hexLength,
    publicKey,
    sign,

    -- * Explicit secret export
    exportBytes,
    exportHex,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Crypto.Ed25519.PublicKey (PublicKey)
import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import Cometa.Crypto.Ed25519.Signature (Signature)
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import Cometa.Error (Error (..))
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.Internal.SigningKey as Internal
import Control.Monad (join)
import Data.ByteString (ByteString)
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | An opaque scoped secret. Escaping a scope does not extend its usable lifetime.
-- Keys of both supported formats use the same operations.
newtype SigningKey = SigningKey Internal.Key

-- DEFINITIONS ----------------------------------------------------------------

-- | Import exactly 32 seed bytes and run the continuation. Invalid length returns
-- 'InvalidEd25519SigningKeyLength' with expected then actual byte counts, without
-- invoking the continuation. Its expected failures are returned directly.
-- Imported bytes remain in application memory after the scoped key closes.
withNormalKey :: ByteString -> (SigningKey -> IO (Either Error value)) -> IO (Either Error value)
withNormalKey bytes action = flatten <$> Internal.withNormalKey bytes (action . SigningKey)

-- | Import exactly 64 expanded scalar and nonce-prefix bytes and run the continuation. This is
-- the Cardano extended format, not a normal seed followed by a public key.
-- Length is validated; an unusable scalar can fail later derivation or signing.
-- Failure and cleanup behavior matches 'withNormalKey'.
withExtendedKey :: ByteString -> (SigningKey -> IO (Either Error value)) -> IO (Either Error value)
withExtendedKey bytes action = flatten <$> Internal.withExtendedKey bytes (action . SigningKey)

-- | Import 64 ASCII hex digits representing a normal 32-byte seed. Both letter
-- cases are accepted; no prefix or whitespace is allowed. Malformed or empty
-- text returns 'InvalidHex'; well-formed wrong length returns
-- 'InvalidEd25519SigningKeyLength'. Closing the key does not erase the supplied text.
withNormalKeyHex :: Text -> (SigningKey -> IO (Either Error value)) -> IO (Either Error value)
withNormalKeyHex text action = flatten <$> Internal.withNormalKeyHex text (action . SigningKey)

-- | Import 128 ASCII hex digits representing an expanded 64-byte scalar and nonce-prefix key.
-- Validation and lifetime limitations match 'withNormalKeyHex'.
withExtendedKeyHex :: Text -> (SigningKey -> IO (Either Error value)) -> IO (Either Error value)
withExtendedKeyHex text action = flatten <$> Internal.withExtendedKeyHex text (action . SigningKey)

-- | Run a continuation with an independent secret copy. Closing the source does
-- not close the copy, and closing the copy does not close its source. The copy
-- closes on every exit. A closed source returns 'SigningKeyClosed'.
withClone :: SigningKey -> (SigningKey -> IO (Either Error value)) -> IO (Either Error value)
withClone (SigningKey key) action = flatten <$> Internal.withClone key (action . SigningKey)

-- | Close the key; repeated calls have no effect. Wait for ongoing operations before returning;
-- no new operation can use the closed handle. Scope exit also closes it.
close :: SigningKey -> IO ()
close (SigningKey key) = Internal.close key

-- | Number of secret bytes: 32 for a normal seed, 64 for an extended key.
-- This reveals no secret contents. A closed handle returns 'SigningKeyClosed'.
byteLength :: SigningKey -> IO (Either Error Int)
byteLength (SigningKey key) = mapFailure <$> Internal.byteLength key

-- | Number of hexadecimal digits, excluding any terminator: 64 or 128. No secret
-- copy is created. A closed handle returns 'SigningKeyClosed'.
hexLength :: SigningKey -> IO (Either Error Int)
hexLength key = fmap (* 2) <$> byteLength key

-- | Derive an immutable public key which remains usable after this key closes.
-- A closed handle returns 'SigningKeyClosed'; derivation failures retain their
-- structured native status without including any secret input.
publicKey :: SigningKey -> IO (Either Error PublicKey)
publicKey (SigningKey key) = do
  result <- Internal.publicKeyBytes key
  pure (mapFailure result >>= PublicKey.fromBytes)

-- | Sign the exact message bytes. Empty messages are supported. The returned
-- signature remains usable after this key closes. This does not prehash or encode
-- a message on the caller's behalf: transaction signing requires the raw body
-- digest, rather than full transaction CBOR or its hexadecimal representation.
-- A closed handle returns 'SigningKeyClosed'; failures never include key bytes.
sign :: SigningKey -> ByteString -> IO (Either Error Signature)
sign (SigningKey key) message = do
  result <- Internal.signBytes key message
  pure (mapFailure result >>= Signature.fromBytes)

-- | Explicitly copy the secret into a new Haskell ByteString. The result can
-- outlive this key and its scope. Closing cannot erase that copy or control
-- copies made by the application; use this only when secret export is intended.
-- A closed handle returns 'SigningKeyClosed'.
exportBytes :: SigningKey -> IO (Either Error ByteString)
exportBytes (SigningKey key) = mapFailure <$> Internal.exportBytes key

-- | Explicitly export lowercase ASCII hexadecimal secret text without a prefix.
-- The exported text remains available after this key closes; closure does not erase it.
-- A closed handle returns 'SigningKeyClosed'.
exportHex :: SigningKey -> IO (Either Error Text)
exportHex key = fmap Hex.encodeHex <$> exportBytes key

-- | Keep acquisition failures flat with the continuation's expected failures.
flatten :: Either Internal.Failure (Either Error value) -> Either Error value
flatten result = join (mapFailure result)

mapFailure :: Either Internal.Failure value -> Either Error value
mapFailure = either (Left . publicFailure) Right

publicFailure :: Internal.Failure -> Error
publicFailure failure = case failure of
  Internal.Closed -> SigningKeyClosed
  Internal.InvalidLength expected actual -> InvalidEd25519SigningKeyLength expected actual
  Internal.InvalidHex -> InvalidHex
  Internal.NativeFailure failureValue -> fromNativeFailure failureValue
