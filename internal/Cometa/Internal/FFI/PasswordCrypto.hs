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
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Borrowed byte inputs, caller-owned PBKDF scratch and operation-owned EMIP3
-- outputs. Calls are safe and non-interruptible: cancellation waits for native
-- unwind before scopes wipe and release their storage. No callbacks or retention.
module Cometa.Internal.FFI.PasswordCrypto (Buffer, cDerive, cEncrypt, cDecrypt, cRelease, cData, cSize, cClear) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word32, Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- TYPES ----------------------------------------------------------------------

data {-# CTYPE "cardano/buffer.h" "cardano_buffer_t" #-} Buffer

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_pbkdf2"
  cDerive :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Word32 -> Ptr Word8 -> CSize -> IO NativeCode

foreign import ccall safe "cometa_emip3_encrypt"
  cEncrypt :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> IO NativeCode

foreign import ccall safe "cometa_emip3_decrypt"
  cDecrypt :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> IO NativeCode

-- | Wipes even on copy exceptions and cancellation; never throws or calls back.
foreign import ccall safe "cometa_password_buffer_release"
  cRelease :: Ptr (Ptr Buffer) -> IO ()

foreign import ccall unsafe "cardano_buffer_get_data"
  cData :: Ptr Buffer -> IO (Ptr Word8)

foreign import capi unsafe "cardano/buffer.h cardano_buffer_get_size"
  cSize :: Ptr Buffer -> IO CSize

foreign import capi safe "cardano/cardano.h cardano_memzero"
  cClear :: Ptr Word8 -> CSize -> IO ()
