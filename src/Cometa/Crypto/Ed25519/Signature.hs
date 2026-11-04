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

-- | Ed25519 signatures as immutable 64-byte values. Import checks encoded
-- length, not whether a signature verifies against a particular key/message.
--
-- @
-- import qualified Cometa.Crypto.Ed25519.Signature as Signature
--
-- roundTrip :: Signature.Signature -> Bool
-- roundTrip value = Signature.fromBytes (Signature.toBytes value) == Right value
-- @
module Cometa.Crypto.Ed25519.Signature
  ( Signature,

    -- * Import
    fromBytes,
    fromHex,

    -- * Inspection
    toBytes,
    toHex,
    byteLength,
    hexLength,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | An immutable 64-byte Ed25519 signature. Equality compares bytes;
-- ordering is lexicographic byte ordering. 'Show' is diagnostic; use 'toHex'
-- for a stable textual representation.
newtype Signature = Signature ByteString
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import exactly 64 bytes. Other lengths return 'InvalidEd25519SignatureLength'.
-- No cryptographic verification is performed.
fromBytes :: ByteString -> Either Error Signature
fromBytes bytes
  | ByteString.length bytes /= 64 = Left (InvalidEd25519SignatureLength (ByteString.length bytes))
  | otherwise = Right (Signature bytes)

-- | Import 128 ASCII hexadecimal digits, accepting either case. No whitespace
-- or prefix is accepted. Empty, odd-length or nonhexadecimal text returns
-- 'InvalidHex'; valid hex of another byte length returns 'InvalidEd25519SignatureLength'.
fromHex :: Text -> Either Error Signature
fromHex text = do
  bytes <- maybe (Left InvalidHex) Right (Hex.decodeHex text)
  if ByteString.null bytes then Left InvalidHex else fromBytes bytes

-- | Retrieve the exact encoded bytes.
toBytes :: Signature -> ByteString
toBytes (Signature bytes) = bytes

-- | Render lowercase ASCII hexadecimal digits without a prefix or whitespace.
toHex :: Signature -> Text
toHex = Hex.encodeHex . toBytes

-- | Encoded byte length, always 64.
byteLength :: Signature -> Int
byteLength = ByteString.length . toBytes

-- | Hexadecimal digit count, always 128. No terminator is included.
hexLength :: Signature -> Int
hexLength value = 2 * byteLength value
