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

-- | Validation and operation failures. Match constructors and status codes to
-- handle errors; diagnostic messages are intended for people.
--
-- @
-- import qualified Cometa.Crypto.Blake2b as Blake2b
-- import qualified Data.ByteString as ByteString
--
-- main :: IO ()
-- main = case Blake2b.fromBytes ByteString.empty of
--   Left err -> print err
--   Right digest -> print digest
-- @
module Cometa.Error
  ( Error (..),
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error.Code (ErrorCode)
import Data.Text (Text)
import Data.Word (Word32)

-- TYPES ----------------------------------------------------------------------

-- | Expected failures returned by Cometa operations. Equality compares every
-- payload, including diagnostic text. 'Show' is diagnostic output.
data Error
  = -- | An operation failed with a cardano-c status code. Unknown numeric codes
    -- remain available through @toNumber@ in "Cometa.Error.Code".
    NativeError
      -- | Operation name, such as @blake2b.compute@; excludes user input.
      !Text
      -- | Exact status code, with a name when recognized.
      !ErrorCode
      -- | Diagnostic message; do not parse it to determine the failure.
      !Text
  | -- | The requested BLAKE2b digest length is outside 16 through 64 bytes.
    InvalidHashLength
      -- | Requested digest length in bytes.
      !Int
  | -- | The digest byte sequence is empty.
    EmptyHash
  | -- | Hexadecimal input is empty, has an odd number of digits, or contains
    -- characters other than ASCII hexadecimal digits. Both cases are accepted.
    InvalidHex
  | -- | An Ed25519 signing-key operation used a handle that has been closed.
    SigningKeyClosed
  | -- | An Ed25519 signing-key input has the wrong byte length for its format.
    InvalidEd25519SigningKeyLength
      -- | Expected byte length: 32 for normal keys, or 64 for extended keys.
      !Int
      -- | Actual input byte length.
      !Int
  | -- | An Ed25519 public key does not contain exactly 32 bytes.
    InvalidEd25519PublicKeyLength
      -- | Actual encoded byte length.
      !Int
  | -- | An Ed25519 signature does not contain exactly 64 bytes.
    InvalidEd25519SignatureLength
      -- | Actual encoded byte length.
      !Int
  | -- | A BIP32 private-key handle has closed.
    Bip32PrivateKeyClosed
  | -- | A BIP32 private key must contain exactly 96 bytes.
    InvalidBip32PrivateKeyLength
      -- | Actual byte count.
      !Int
  | -- | A BIP32 public key must contain exactly 64 bytes.
    InvalidBip32PublicKeyLength
      -- | Actual byte count.
      !Int
  | -- | BIP39 entropy must contain 16, 20, 24, 28 or 32 bytes.
    InvalidBip39EntropyLength
      -- | Actual byte count.
      !Int
  | -- | A mnemonic requires 12, 15, 18, 21 or 24 words.
    InvalidBip39WordCount
      -- | Actual number of words.
      !Int
  | -- | A mnemonic word is empty or contains characters outside lowercase ASCII.
    InvalidBip39Word
      -- | One-based word position; excludes the word itself.
      !Int
  | -- | At least one word is absent from the English BIP39 dictionary.
    UnknownBip39Word
  | -- | The mnemonic checksum does not agree with its entropy.
    InvalidBip39Checksum
  | -- | PBKDF2 requires a nonempty salt.
    EmptyPbkdf2Salt
  | -- | PBKDF2 iteration count is outside 1 through 4294967295 inclusive.
    InvalidPbkdf2Iterations
      -- | Requested iteration count.
      !Integer
  | -- | PBKDF2 output byte count is outside its documented bounds.
    InvalidPbkdf2OutputLength
      -- | Requested output byte count.
      !Integer
  | -- | EMIP3 plaintext exceeds its documented size bounds.
    InvalidEmip3PlaintextLength
      -- | Actual plaintext byte count.
      !Int
  | -- | EMIP3 envelope is outside its documented size bounds.
    InvalidEmip3EnvelopeLength
      -- | Actual encoded byte count.
      !Int
  | -- | Public derivation requires soft indices below 2^31.
    HardenedPublicDerivation
      -- | First hardened encoded index encountered.
      !Word32
  | -- | A CBOR integer is outside the supported primitive range, from
    -- @-2^64@ through @2^64 - 1@ inclusive. Tagged bignums are not encoded here.
    InvalidCborInteger
      -- | Requested integer value.
      !Integer
  | -- | A decoded CBOR text string contains invalid UTF-8.
    InvalidCborUtf8
  | -- | An operation reported success but did not produce a valid result.
    NativeContractViolation
      -- | Operation name; excludes user input.
      !Text
  deriving (Eq, Show)
