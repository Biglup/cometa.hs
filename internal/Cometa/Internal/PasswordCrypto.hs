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

-- | Scoped password crypto marshaling. Public validation precedes these calls.
-- PBKDF scratch uses heap allocation, not an input-sized stack allocation.
-- All plaintext native buffers are wiped on every exit after foreign unwind.
-- Explicitly exported immutable host copies have application-managed lifetime.
module Cometa.Internal.PasswordCrypto (deriveBytes, encrypt, decryptBytes) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode, cErrorMessage, success)
import qualified Cometa.Internal.FFI.PasswordCrypto as Native
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (copyStaticText, withOwnedOutput)
import Control.Exception (bracket, evaluate, finally)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Data.Word (Word32, Word8)
import Foreign.C.Types (CSize)
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)

-- DEFINITIONS ----------------------------------------------------------------

deriveBytes :: ByteString -> ByteString -> Word32 -> Int -> IO (Either NativeFailure ByteString)
deriveBytes password salt iterations size =
  withBytes password $ \passwordPtr passwordSize ->
    withBytes salt $ \saltPtr saltSize ->
      withScratch size $ \output -> do
        status <- Native.cDerive passwordPtr passwordSize saltPtr saltSize iterations output (fromIntegral size)
        if status == success
          then Right <$> copyBytes output size
          else Left <$> nativeFailure "pbkdf2.deriveBytes" status

-- Cleanup is installed before the native call can populate scratch storage.
withScratch :: Int -> (Ptr Word8 -> IO a) -> IO a
withScratch size = bracket (mallocBytes size) (\pointer -> Native.cClear pointer (fromIntegral size) `finally` free pointer)

encrypt :: ByteString -> ByteString -> IO (Either NativeFailure ByteString)
encrypt password plaintext = transform "emip3.encrypt" Native.cEncrypt password plaintext (ByteString.length plaintext + 60)

decryptBytes :: ByteString -> ByteString -> IO (Either NativeFailure ByteString)
decryptBytes password ciphertext = transform "emip3.decryptBytes" Native.cDecrypt password ciphertext (ByteString.length ciphertext - 60)

transform :: Text -> (Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr Native.Buffer) -> IO NativeCode) -> ByteString -> ByteString -> Int -> IO (Either NativeFailure ByteString)
transform operation invoke password input expectedSize =
  withBytes password $ \passwordPtr passwordSize ->
    withBytes input $ \inputPtr inputSize ->
      withOwnedOutput operation Native.cRelease (invoke inputPtr inputSize passwordPtr passwordSize) $ \buffer -> do
        size <- Native.cSize buffer
        pointer <- Native.cData buffer
        if toInteger size /= toInteger expectedSize || (expectedSize > 0 && pointer == nullPtr)
          then pure (Left (NativeContractFailure operation))
          else
            if expectedSize == 0
              then pure (Right ByteString.empty)
              else Right <$> copyBytes pointer expectedSize

withBytes :: ByteString -> (Ptr Word8 -> CSize -> IO a) -> IO a
withBytes bytes action = ByteString.useAsCStringLen bytes $ \(pointer, size) -> action (castPtr pointer) (fromIntegral size)

copyBytes :: Ptr Word8 -> Int -> IO ByteString
copyBytes pointer size = do
  bytes <- ByteString.packCStringLen (castPtr pointer, size)
  evaluate (ByteString.length bytes `seq` bytes)

nativeFailure :: Text -> NativeCode -> IO NativeFailure
nativeFailure operation status = do
  diagnostic <- cErrorMessage status >>= copyStaticText
  evaluate (NativeFailure operation (fromIntegral status) diagnostic)
