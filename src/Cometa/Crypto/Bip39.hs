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

-- | English BIP39 recovery phrases with validated word counts and checksums.
--
-- Mnemonics contain wallet secrets. They have no 'Show' or equality instance.
-- Import and export create ordinary Haskell text/byte values whose lifetimes
-- are managed by the caller; this API does not guarantee their erasure. Never
-- log exported phrases or use deterministic examples for real wallets.
-- Pure evaluation may share secret values and extend their retention; it does
-- not promise the timing or number of conversions.
--
-- @
-- import qualified Cometa.Crypto.Bip39 as Bip39
-- import qualified Data.ByteString as ByteString
--
-- main :: IO ()
-- main =
--   case Bip39.fromEntropy (ByteString.replicate 16 0) of -- test only
--     Left err -> print err
--     Right mnemonic -> print (Bip39.wordCount mnemonic)
-- @
module Cometa.Crypto.Bip39
  ( Mnemonic,

    -- * Construction
    fromEntropy,
    fromText,
    fromWords,

    -- * Inspection
    wordCount,

    -- * Explicit secret export
    exportText,
    exportEntropy,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Internal.Bip39Pure (Mnemonic)
import qualified Cometa.Internal.Bip39Pure as Internal
import Data.ByteString (ByteString)
import Data.Text (Text)

-- DEFINITIONS ----------------------------------------------------------------

-- | Convert supplied entropy into a phrase. Exactly 16, 20, 24, 28 or 32 bytes
-- are accepted; other sizes return 'InvalidBip39EntropyLength'. This operation
-- does not generate randomness. The caller must supply securely generated
-- entropy for a real wallet. Native failures return 'NativeError'; a violated
-- result invariant returns 'NativeContractViolation'.
fromEntropy :: ByteString -> Either Error Mnemonic
fromEntropy = Internal.fromEntropy

-- | Parse a phrase, splitting on Unicode whitespace and discarding leading and
-- trailing whitespace. Words are case sensitive: only lowercase ASCII English
-- BIP39 words are accepted, without spelling correction or normalization.
-- Returns 'InvalidBip39WordCount', 'InvalidBip39Word' (one-based position),
-- 'UnknownBip39Word', or 'InvalidBip39Checksum'. Error values never include the
-- supplied words. Unexpected native failures return 'NativeError'; a violated
-- result invariant returns 'NativeContractViolation'.
fromText :: Text -> Either Error Mnemonic
fromText = Internal.fromText

-- | Validate individual words and their checksum. Each list element must be
-- one lowercase ASCII word; embedded whitespace, NUL, upper case and non-ASCII
-- characters return 'InvalidBip39Word'. Failures match 'fromText'.
fromWords :: [Text] -> Either Error Mnemonic
fromWords = Internal.fromWords

-- | Number of words in the validated phrase.
wordCount :: Mnemonic -> Int
wordCount = Internal.wordCount

-- | Export the secret phrase as lowercase words separated by single ASCII
-- spaces. The returned text is ordinary caller-managed secret material.
exportText :: Mnemonic -> Text
exportText = Internal.exportText

-- | Export the secret entropy bytes (16, 20, 24, 28 or 32 bytes). This is the
-- entropy accepted by @Cometa.Crypto.Bip32.PrivateKey.withEntropy@,
-- not the 64-byte seed produced by BIP39's separate passphrase KDF.
-- The returned bytes are ordinary caller-managed secret material. Native
-- failures return 'NativeError'; a violated result invariant returns
-- 'NativeContractViolation'.
exportEntropy :: Mnemonic -> Either Error ByteString
exportEntropy = Internal.exportEntropy
