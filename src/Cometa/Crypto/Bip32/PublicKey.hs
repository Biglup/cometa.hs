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

-- | Cardano Ed25519-BIP32 public keys: a 32-byte verification key followed by a
-- 32-byte chain code. These are not secp256k1 Bitcoin BIP32 keys. Import validates
-- length only; an invalid curve point can fail later derivation.
--
-- @
-- import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
--
-- roundTrip key = PublicKey.fromBytes (PublicKey.toBytes key) == Right key
-- @
module Cometa.Crypto.Bip32.PublicKey
  ( PublicKey,

    -- * Import and serialization
    fromBytes,
    fromHex,
    toBytes,
    toHex,
    byteLength,
    hexLength,

    -- * Derivation and conversion
    derive,
    toEd25519,
    hash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as Ed25519
import Cometa.Error (Error (..))
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.FFI.Bip32 as Native
import qualified Cometa.Internal.FFI.Native as Status
import Cometa.Internal.Failure (NativeFailure (..))
import qualified Cometa.Internal.Hex as Hex
import Cometa.Internal.Ownership (copyStaticText)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Data.Word (Word32)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (withArrayLen)
import Foreign.Ptr (castPtr)

-- TYPES ----------------------------------------------------------------------

-- | Immutable 64-byte public key and chain code. Equality compares exact bytes;
-- ordering is lexicographic. 'Show' is diagnostic; 'toHex' is stable serialization.
data PublicKey = PublicKey !Ed25519.PublicKey !ByteString deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import exactly 64 bytes; other lengths return 'InvalidBip32PublicKeyLength'.
-- Curve-point validity is not checked.
fromBytes :: ByteString -> Either Error PublicKey
fromBytes bytes
  | ByteString.length bytes /= 64 = Left (InvalidBip32PublicKeyLength (ByteString.length bytes))
  | otherwise = do
      key <- Ed25519.fromBytes (ByteString.take 32 bytes)
      pure (PublicKey key (ByteString.drop 32 bytes))

-- | Import 128 ASCII hex digits in either case, without prefix or whitespace.
-- Empty or malformed text returns 'InvalidHex'; a well-formed wrong length returns
-- 'InvalidBip32PublicKeyLength'.
fromHex :: Text -> Either Error PublicKey
fromHex text = do
  bytes <- maybe (Left InvalidHex) Right (Hex.decodeHex text)
  if ByteString.null bytes then Left InvalidHex else fromBytes bytes

-- | Retrieve all 64 bytes, including the chain code.
toBytes :: PublicKey -> ByteString
toBytes (PublicKey key chainCode) = Ed25519.toBytes key <> chainCode

-- | Render 128 lowercase ASCII hexadecimal digits without prefix or whitespace.
toHex :: PublicKey -> Text
toHex = Hex.encodeHex . toBytes

-- | Encoded length, always 64 bytes.
byteLength :: PublicKey -> Int
byteLength _ = 64

-- | Hexadecimal digit count, always 128, excluding a terminator.
hexLength :: PublicKey -> Int
hexLength key = 2 * byteLength key

-- | Derive a path in order. Each encoded index must be in @0..2^31-1@;
-- any high-bit (hardened) index returns 'HardenedPublicDerivation' before native
-- work. An empty path returns the original value. Native derivation failures
-- return 'NativeError'. The source is unchanged.
derive :: PublicKey -> [Word32] -> IO (Either Error PublicKey)
derive key path
  | Just index <- firstHardened path = pure (Left (HardenedPublicDerivation index))
  | null path = pure (Right key)
  | otherwise = ByteString.useAsCString (toBytes key) $ \bytes ->
      withArrayLen path $ \size indices -> allocaBytes 64 $ \output -> do
        code <- Native.cDerivePublic (castPtr bytes) indices (fromIntegral size) output
        if code == Status.success
          then fromBytes <$> ByteString.packCStringLen (castPtr output, 64)
          else do
            message <- Status.cErrorMessage code >>= copyStaticText
            pure (Left (fromNativeFailure (NativeFailure "bip32.publicKey.derive" (toInteger code) message)))
  where
    firstHardened [] = Nothing
    firstHardened (index : rest)
      | index >= 0x80000000 = Just index
      | otherwise = firstHardened rest

-- | Discard the chain code and return the first 32 bytes as an Ed25519 public
-- key. This does not validate curve membership or identity.
toEd25519 :: PublicKey -> Ed25519.PublicKey
toEd25519 (PublicKey key _) = key

-- | Compute BLAKE2b-224 over all 64 bytes, including the chain code, matching
-- the BIP32 public-key hash operation. For a payment/stake verification-key digest,
-- convert with 'toEd25519' and use 'Ed25519.hash' instead. Failures return 'NativeError'.
hash :: PublicKey -> IO (Either Error Blake2b.Blake2bHash)
hash = Blake2b.compute 28 . toBytes
