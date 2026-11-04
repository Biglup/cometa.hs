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

-- | Raw, private declarations. Status values use an explicit unsigned C ABI.
-- All input buffers are borrowed for the call; successful hash
-- output owns one reference. The data observer borrows from that reference.
-- No function in this module retains a Haskell buffer or invokes a callback.
-- Const-pointer observers use ccall because GHC's CAPI wrappers discard const;
-- their signatures are audited against the same pinned headers.
module Cometa.Internal.FFI.Native
  ( NativeHash,
    NativeCode,
    success,
    cCompute,
    cUnref,
    cData,
    cSize,
    cErrorMessage,
    cVersion,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- TYPES ----------------------------------------------------------------------

-- | Opaque native allocation; never dereferenced by Haskell.
data {-# CTYPE "cardano/crypto/blake2b_hash.h" "cardano_blake2b_hash_t" #-} NativeHash

-- | Explicit unsigned C status ABI. CAPI calls convert native enum results;
-- the C adapter converts enum parameters and all raw status-returning calls.
-- No native enum representation is assumed by a direct Haskell import.
type NativeCode = CUInt

-- DEFINITIONS ---------------------------------------------------------------

-- | Successful native status.
success :: NativeCode
success = 0

-- FOREIGN IMPORTS ------------------------------------------------------------

-- | Safe because hashing can take time proportional to unbounded input length.
foreign import capi safe "cardano/crypto/blake2b_hash.h cardano_blake2b_compute_hash"
  cCompute :: Ptr Word8 -> CSize -> CSize -> Ptr (Ptr NativeHash) -> IO NativeCode

-- | Nonblocking bounded destructor. Decrements the reference in the slot and
-- clears it when that reference was the final one. A released alias must not
-- be used again, even when another owner leaves the pointer non-null.
foreign import capi unsafe "cardano/crypto/blake2b_hash.h cardano_blake2b_hash_unref"
  cUnref :: Ptr (Ptr NativeHash) -> IO ()

-- | Borrowed bytes remain valid only while an owner retains the hash.
foreign import ccall unsafe "cardano_blake2b_hash_get_data"
  cData :: Ptr NativeHash -> IO (Ptr Word8)

-- | Digest byte length; the native function returns zero for a null hash.
foreign import capi unsafe "cardano/crypto/blake2b_hash.h cardano_blake2b_hash_get_bytes_size"
  cSize :: Ptr NativeHash -> IO CSize

-- | Returned string is static and must be copied, never freed.
foreign import ccall unsafe "cometa_error_message"
  cErrorMessage :: NativeCode -> IO CString

-- | Borrowed static, NUL-terminated version string; copy it and never free it.
foreign import ccall unsafe "cardano_get_lib_version"
  cVersion :: IO CString
