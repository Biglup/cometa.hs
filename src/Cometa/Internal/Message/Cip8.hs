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
{-# OPTIONS_HADDOCK hide #-}

-- | Borrowed inputs and scoped key access; both native output slots are released
-- on success, native error, copying exception and cancellation.
module Cometa.Internal.Message.Cip8
  ( Binding,
    addressBinding,
    keyHashBinding,
    SignedMessage (..),
    sign,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Credential as Credential
import Cometa.Crypto.Ed25519.SigningKey (SigningKey)
import Cometa.Error (Error (..))
import Cometa.Internal.Ed25519SigningKey (SigningKey (..))
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.FFI.Cip8 as Native
import qualified Cometa.Internal.FFI.Native as Status
import qualified Cometa.Internal.FFI.PasswordCrypto as Buffer
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (copyStaticText)
import qualified Cometa.Internal.SigningKey as Key
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word8)
import Foreign.C.Types (CSize, CUInt)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | A validated address or 28-byte key hash to include in the protected headers.
-- This value does not establish a relationship with a signing key.
data Binding = Binding !CUInt !ByteString deriving (Eq, Show)

-- | Two independently owned CBOR encodings, without hexadecimal conversion.
-- The signature includes the payload and the COSE key includes its public key.
data SignedMessage = SignedMessage
  { -- | CBOR-encoded COSE_Sign1 containing the payload and signature.
    coseSign1 :: !ByteString,
    -- | CBOR-encoded COSE_Key containing the Ed25519 public key.
    coseKey :: !ByteString
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Bind the signed headers to the complete validated address bytes.
addressBinding :: Address.Address -> Binding
addressBinding = Binding 0 . Address.toBytes

-- | Bind the signed headers to a validated key hash of any credential role.
keyHashBinding :: Credential.KeyHash purpose -> Binding
keyHashBinding = Binding 1 . Credential.keyHashBytes

-- | Sign a nonempty binary payload using a live normal or extended key.
-- Empty input returns native @InvalidArgument@; a closed key returns
-- 'SigningKeyClosed'. The result can outlive the key's scope.
sign :: SigningKey -> Binding -> ByteString -> IO (Either Error SignedMessage)
sign (SigningKey key) (Binding kind binding) message =
  withBytes binding $ \bindingPointer bindingSize ->
    withBytes message $ \messagePointer messageSize -> do
      result <- Key.withKey key $ \pointer ->
        withOutput $ \signSlot -> withOutput $ \keySlot -> do
          code <- Native.cSign pointer kind bindingPointer bindingSize messagePointer messageSize signSlot keySlot
          if code /= Status.success
            then do
              diagnostic <- Status.cErrorMessage code >>= copyStaticText
              pure (Left (Key.NativeFailure (NativeFailure "cip8.sign" (toInteger code) diagnostic)))
            else do
              encodedSign <- copyBuffer signSlot
              encodedKey <- copyBuffer keySlot
              pure $ case (encodedSign, encodedKey) of
                (Just signBytes, Just keyBytes) -> Right (SignedMessage signBytes keyBytes)
                _ -> Left (Key.NativeFailure (NativeContractFailure "cip8.sign"))
      pure $ case result of
        Right value -> Right value
        Left Key.Closed -> Left SigningKeyClosed
        Left (Key.NativeFailure failure) -> Left (fromNativeFailure failure)
        Left _ -> Left (NativeContractViolation "cip8.sign")

withBytes :: ByteString -> (Ptr Word8 -> CSize -> IO value) -> IO value
withBytes bytes action = ByteString.useAsCStringLen bytes $ \(pointer, size) -> action (castPtr pointer) (fromIntegral size)

withOutput :: (Ptr (Ptr Buffer.Buffer) -> IO value) -> IO value
withOutput action = alloca $ \slot -> bracket (poke slot nullPtr >> pure slot) Buffer.cRelease action

copyBuffer :: Ptr (Ptr Buffer.Buffer) -> IO (Maybe ByteString)
copyBuffer slot = do
  pointer <- peek slot
  if pointer == nullPtr
    then pure Nothing
    else do
      size <- Buffer.cSize pointer
      bytes <- Buffer.cData pointer
      if size == 0 || toInteger size > toInteger (maxBound :: Int) || bytes == nullPtr
        then pure Nothing
        else Just <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)
