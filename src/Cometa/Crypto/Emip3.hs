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

-- | Password-encrypted storage using EMIP-003: PBKDF2-HMAC-SHA512 with
-- 19162 iterations and a 32-byte key, then ChaCha20-Poly1305 with empty AAD.
-- The encoded envelope is salt (32 bytes), nonce (12), tag (16), ciphertext.
-- Passwords and plaintext are raw bytes with no normalization. Plaintext and
-- passwords supplied by the caller, and exported plaintext, are not erased.
--
-- @
-- import qualified Cometa.Crypto.Emip3 as Emip3
-- store password bytes = Emip3.encrypt password bytes
-- load password envelope = Emip3.decryptBytes password envelope
-- @
module Cometa.Crypto.Emip3 (encrypt, decryptBytes) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.PasswordCrypto as Internal
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString

-- DEFINITIONS ----------------------------------------------------------------

-- | Encrypt plaintext, including empty data, using a fresh random salt and
-- nonce. Password comes first and may be empty or contain NUL. Plaintext must
-- contain @0..min(maxBound - 60, 274877906880)@ bytes, where @maxBound :: Int@;
-- other lengths return 'InvalidEmip3PlaintextLength' before encryption.
-- Success is exactly 60 bytes longer than the plaintext. Random generation
-- and allocation occur in 'IO'. Other failures return 'NativeError'; allocation
-- exceptions propagate. Cancellation waits for the operation and cleanup.
encrypt :: ByteString -> ByteString -> IO (Either Error ByteString)
encrypt password plaintext
  | toInteger size > min (toInteger (maxBound :: Int) - 60) 274877906880 = pure (Left (InvalidEmip3PlaintextLength size))
  | otherwise = either (Left . fromNativeFailure) Right <$> Internal.encrypt password plaintext
  where
    size = ByteString.length plaintext

-- | Authenticate and explicitly export plaintext from an encoded envelope.
-- Password comes first and may be empty or contain NUL. Envelopes must contain
-- 60 through 274877906940 bytes; other lengths return
-- 'InvalidEmip3EnvelopeLength'. A 60-byte envelope authenticates empty plaintext.
-- A wrong password or modified envelope
-- returns 'NativeError' with the native generic failure code and never returns
-- plaintext. Allocation exceptions propagate. Cancellation waits for native
-- completion and cleanup. Returned plaintext has application-managed lifetime;
-- this function cannot erase it or subsequent copies.
decryptBytes :: ByteString -> ByteString -> IO (Either Error ByteString)
decryptBytes password envelope
  | ByteString.length envelope < 60 || toInteger (ByteString.length envelope) > 274877906940 = pure (Left (InvalidEmip3EnvelopeLength (ByteString.length envelope)))
  | otherwise = either (Left . fromNativeFailure) Right <$> Internal.decryptBytes password envelope
