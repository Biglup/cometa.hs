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

-- | Ed25519 public keys as immutable 32-byte values. Import checks encoded
-- length; it does not establish that a key belongs to a particular person or
-- that a signature verifies. Use 'verify' to check a message and signature.
--
-- @
-- import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
--
-- roundTrip :: PublicKey.PublicKey -> Bool
-- roundTrip value = PublicKey.fromBytes (PublicKey.toBytes value) == Right value
-- @
module Cometa.Crypto.Ed25519.PublicKey
  ( PublicKey,

    -- * Import
    fromBytes,
    fromHex,

    -- * Inspection
    toBytes,
    toHex,
    byteLength,
    hexLength,

    -- * Verification and hashing
    verify,
    hash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Crypto.Ed25519.Signature (Signature)
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.FFI.Ed25519Values as Native
import qualified Cometa.Internal.FFI.Native as Status
import Cometa.Internal.Failure (NativeFailure (..))
import qualified Cometa.Internal.Hex as Hex
import Cometa.Internal.Ownership (copyHashResult, copyStaticText)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (castPtr)
import Foreign.Storable (peek)

-- TYPES ----------------------------------------------------------------------

-- | An immutable 32-byte Ed25519 public key. Equality compares bytes;
-- ordering is lexicographic byte ordering. 'Show' is diagnostic; use 'toHex'
-- for a stable textual representation.
newtype PublicKey = PublicKey ByteString
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import exactly 32 bytes. Other lengths return 'InvalidEd25519PublicKeyLength'.
-- Only length is validated; this constructor does not check curve-point validity.
fromBytes :: ByteString -> Either Error PublicKey
fromBytes bytes
  | ByteString.length bytes /= 32 = Left (InvalidEd25519PublicKeyLength (ByteString.length bytes))
  | otherwise = Right (PublicKey bytes)

-- | Import 64 ASCII hexadecimal digits, accepting either case. No whitespace
-- or prefix is accepted. Empty, odd-length or nonhexadecimal text returns
-- 'InvalidHex'; valid hex of another byte length returns 'InvalidEd25519PublicKeyLength'.
fromHex :: Text -> Either Error PublicKey
fromHex text = do
  bytes <- maybe (Left InvalidHex) Right (Hex.decodeHex text)
  if ByteString.null bytes then Left InvalidHex else fromBytes bytes

-- | Retrieve the exact encoded bytes.
toBytes :: PublicKey -> ByteString
toBytes (PublicKey bytes) = bytes

-- | Render lowercase ASCII hexadecimal digits without a prefix or whitespace.
toHex :: PublicKey -> Text
toHex = Hex.encodeHex . toBytes

-- | Encoded byte length, always 32.
byteLength :: PublicKey -> Int
byteLength = ByteString.length . toBytes

-- | Hexadecimal digit count, always 64. No terminator is included.
hexLength :: PublicKey -> Int
hexLength value = 2 * byteLength value

-- | Check an Ed25519 signature for the exact message bytes. Empty messages and
-- embedded NUL bytes are supported. 'Right' 'True' means verification succeeded;
-- 'Right' 'False' means it did not. Allocation or other operation failures return
-- 'NativeError'. This operation uses ordinary Ed25519 on the supplied message.
verify :: PublicKey -> ByteString -> Signature -> IO (Either Error Bool)
verify publicKey message signature =
  ByteString.useAsCStringLen (toBytes publicKey) $ \(keyBytes, keySize) ->
    ByteString.useAsCStringLen (Signature.toBytes signature) $ \(signatureBytes, signatureSize) ->
      ByteString.useAsCStringLen message $ \(messageBytes, messageSize) ->
        alloca $ \verified -> do
          code <- Native.cVerify (castPtr keyBytes) (fromIntegral keySize) (castPtr signatureBytes) (fromIntegral signatureSize) (castPtr messageBytes) (fromIntegral messageSize) verified
          if code == Status.success
            then Right . (/= 0) <$> peek verified
            else do
              diagnostic <- Status.cErrorMessage code >>= copyStaticText
              pure (Left (NativeError "ed25519.publicKey.verify" (Code.fromNumber (toInteger code)) diagnostic))

-- | Compute the 28-byte BLAKE2b-224 digest of the encoded public key. The result
-- is a general digest, without a payment/stake role distinction. Operation
-- failures return 'NativeError'.
hash :: PublicKey -> IO (Either Error Blake2b.Blake2bHash)
hash publicKey =
  ByteString.useAsCStringLen (toBytes publicKey) $ \(input, size) -> do
    result <- copyHashResult "ed25519.publicKey.hash" (Native.cPublicKeyHash (castPtr input) (fromIntegral size))
    pure $ case result of
      Left failure -> Left (fromNativeFailure failure)
      Right bytes
        | ByteString.length bytes /= 28 -> Left (NativeContractViolation "ed25519.publicKey.hash")
        | otherwise -> Blake2b.fromBytes bytes

-- | Preserve the exact native failure at the public operation boundary.
fromNativeFailure :: NativeFailure -> Error
fromNativeFailure failure = case failure of
  NativeFailure operation code message -> NativeError operation (Code.fromNumber code) message
  NativeContractFailure operation -> NativeContractViolation operation
