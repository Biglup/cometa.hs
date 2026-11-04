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
{-# LANGUAGE OverloadedStrings #-}

-- | BLAKE2b digests as immutable byte sequences. This general digest type does
-- not distinguish payment, stake, or script hashes.
--
-- @
-- import qualified Cometa.Crypto.Blake2b as Blake2b
-- import qualified Data.ByteString.Char8 as ByteString
--
-- main :: IO ()
-- main = do
--   result <- Blake2b.compute 32 (ByteString.pack "abc")
--   print (Blake2b.toHex <$> result)
-- @
module Cometa.Crypto.Blake2b
  ( Blake2bHash,

    -- * Hashing
    compute,

    -- * Importing digests
    fromBytes,
    fromHex,

    -- * Inspection
    toBytes,
    toHex,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.FFI.Native as Native
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (copyHashResult)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word8)
import Foreign.Ptr (castPtr)

-- TYPES ----------------------------------------------------------------------

-- | A nonempty digest byte sequence. Equality compares bytes; ordering is
-- lexicographic byte ordering.
-- 'Show' is diagnostic; use 'toHex' for a stable textual encoding.
newtype Blake2bHash = Blake2bHash ByteString
  deriving (Eq, Ord, Show)

-- HASHING --------------------------------------------------------------------

-- | Compute an unkeyed digest with an output length of 16 through 64 bytes.
-- Invalid output lengths return 'InvalidHashLength'. Empty messages are currently
-- unsupported and return 'NativeError' with code 'Code.OutOfBoundsMemoryRead'.
-- Other cardano-c failures also return 'NativeError'.
compute ::
  -- | Digest length in bytes, from 16 through 64 inclusive.
  Int ->
  -- | Nonempty message to hash.
  ByteString ->
  -- | Digest with the requested length, or a validation or operation failure.
  IO (Either Error Blake2bHash)
compute hashLength bytes
  | hashLength < 16 || hashLength > 64 = pure (Left (InvalidHashLength hashLength))
  | otherwise =
      ByteString.useAsCStringLen bytes $ \(input, size) ->
        either (Left . fromNativeFailure) (Right . Blake2bHash)
          <$> copyHashResult "blake2b.compute" (Native.cCompute (castPtr input) (fromIntegral size) (fromIntegral hashLength))

-- IMPORTING DIGESTS ----------------------------------------------------------

-- | Import digest bytes without hashing them. Any nonempty length is accepted;
-- this operation does not assert a particular digest role or algorithm variant.
-- Empty input returns 'EmptyHash'.
fromBytes :: ByteString -> Either Error Blake2bHash
fromBytes bytes
  | ByteString.null bytes = Left EmptyHash
  | otherwise = Right (Blake2bHash bytes)

-- | Import nonempty, even-length ASCII hexadecimal text, accepting both cases.
-- Malformed text returns 'InvalidHex'. No whitespace or prefix is accepted.
fromHex :: Text -> Either Error Blake2bHash
fromHex text =
  case decodeHex (Text.unpack text) of
    Nothing -> Left InvalidHex
    Just [] -> Left InvalidHex
    Just bytes -> fromBytes (ByteString.pack bytes)

-- INSPECTION -----------------------------------------------------------------

-- | Observe the immutable digest bytes.
toBytes :: Blake2bHash -> ByteString
toBytes (Blake2bHash bytes) = bytes

-- | Encode the digest as lowercase ASCII hex, without a prefix or whitespace.
toHex :: Blake2bHash -> Text
toHex = Text.pack . concatMap encodeByte . ByteString.unpack . toBytes
  where
    encodeByte byte = [digit (byte `div` 16), digit (byte `mod` 16)]
    digit value
      | value < 10 = toEnum (fromIntegral value + fromEnum '0')
      | otherwise = toEnum (fromIntegral value - 10 + fromEnum 'a')

-- INTERNAL HELPERS -----------------------------------------------------------

-- | Total hexadecimal decoder: no unchecked indexing or partial digit conversion.
decodeHex :: String -> Maybe [Word8]
decodeHex [] = Just []
decodeHex (high : low : rest) = do
  highValue <- hexDigit high
  lowValue <- hexDigit low
  remaining <- decodeHex rest
  pure ((highValue * 16 + lowValue) : remaining)
decodeHex [_] = Nothing

hexDigit :: Char -> Maybe Word8
hexDigit character
  | isDigit character = Just (offset '0')
  | character >= 'a' && character <= 'f' = Just (10 + offset 'a')
  | character >= 'A' && character <= 'F' = Just (10 + offset 'A')
  | otherwise = Nothing
  where
    offset start = fromIntegral (fromEnum character - fromEnum start)

-- | Translate a private native snapshot at the public domain boundary.
fromNativeFailure :: NativeFailure -> Error
fromNativeFailure failure = case failure of
  NativeFailure operation code message -> NativeError operation (Code.fromNumber code) message
  NativeContractFailure operation -> NativeContractViolation operation
