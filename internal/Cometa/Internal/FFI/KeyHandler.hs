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
{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Synchronous native handlers. Constructors copy input and borrow their callback
-- until final release. Every callback-capable entry is safe and non-interruptible.
module Cometa.Internal.FFI.KeyHandler
  ( NativeHandler,
    PassphraseCallback,
    wrapPassphrase,
    cNew,
    cEdNew,
    cDeserialize,
    cUnref,
    cName,
    cSerialize,
    cAccount,
    cPublic,
    cSign,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Cometa.Internal.FFI.PasswordCrypto (Buffer)
import Cometa.Internal.FFI.SigningKey (NativeKey)
import Data.Int (Int32)
import Data.Word (Word32, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (FunPtr, Ptr)

-- TYPES ----------------------------------------------------------------------

data NativeHandler

type PassphraseCallback = Ptr Word8 -> CSize -> IO Int32

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall "wrapper" wrapPassphrase :: PassphraseCallback -> IO (FunPtr PassphraseCallback)

foreign import ccall safe "cardano_software_secure_key_handler_new"
  cNew :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> FunPtr PassphraseCallback -> Ptr (Ptr NativeHandler) -> IO NativeCode

foreign import ccall safe "cardano_software_secure_key_handler_ed25519_new"
  cEdNew :: Ptr NativeKey -> Ptr Word8 -> CSize -> FunPtr PassphraseCallback -> Ptr (Ptr NativeHandler) -> IO NativeCode

foreign import ccall safe "cardano_software_secure_key_handler_deserialize"
  cDeserialize :: Ptr Word8 -> CSize -> FunPtr PassphraseCallback -> Ptr (Ptr NativeHandler) -> IO NativeCode

foreign import ccall unsafe "cardano_secure_key_handler_unref"
  cUnref :: Ptr (Ptr NativeHandler) -> IO ()

foreign import ccall safe "cardano_secure_key_handler_serialize"
  cSerialize :: Ptr NativeHandler -> Ptr (Ptr Buffer) -> IO NativeCode

foreign import ccall safe "cometa_handler_account"
  cAccount :: Ptr NativeHandler -> Word32 -> Word32 -> Word32 -> Ptr Word8 -> IO NativeCode

foreign import ccall safe "cometa_handler_public"
  cPublic :: Ptr NativeHandler -> Ptr Word8 -> IO NativeCode

-- | Borrowed diagnostic name copied under the operation lock.
foreign import ccall unsafe "cardano_secure_key_handler_get_name"
  cName :: Ptr NativeHandler -> IO CString

-- | Borrow the handler, transaction bytes and flat path components through the
-- complete callback-capable call. Success transfers one public witness buffer.
foreign import ccall safe "cometa_handler_sign"
  cSign :: Ptr NativeHandler -> Ptr Word8 -> CSize -> CUInt -> Ptr Word32 -> CSize -> Ptr (Ptr Buffer) -> IO NativeCode
