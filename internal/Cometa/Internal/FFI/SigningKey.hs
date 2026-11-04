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

-- | Private synchronous secret-key ABI. Input storage is borrowed until return;
-- constructors and clone produce one owned reference. Key operations require the
-- resource lock, including observers, so closing cannot race a live pointer.
module Cometa.Internal.FFI.SigningKey
  ( NativeKey,
    cFromNormalBytes,
    cFromExtendedBytes,
    cFromNormalHex,
    cFromExtendedHex,
    cClone,
    cUnref,
    cData,
    cSize,
    cPublicKey,
    cSign,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- TYPES ----------------------------------------------------------------------

-- | Native secret allocation; never dereferenced or exposed publicly by Haskell.
data NativeKey

-- FOREIGN IMPORTS ------------------------------------------------------------

-- Constructors copy borrowed input; output slots are initialized by both layers.
foreign import ccall safe "cometa_signing_key_from_normal_bytes"
  cFromNormalBytes :: Ptr Word8 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_signing_key_from_extended_bytes"
  cFromExtendedBytes :: Ptr Word8 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_signing_key_from_normal_hex"
  cFromNormalHex :: Ptr Word8 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_signing_key_from_extended_hex"
  cFromExtendedHex :: Ptr Word8 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

-- | Independent secret copy; no mutable storage or lifetime is shared.
foreign import ccall safe "cometa_signing_key_clone"
  cClone :: Ptr NativeKey -> Ptr (Ptr NativeKey) -> IO NativeCode

-- | Bounded release; final destruction wipes the native key buffer before free.
foreign import ccall unsafe "cometa_signing_key_unref"
  cUnref :: Ptr (Ptr NativeKey) -> IO ()

-- | Borrow secret bytes only while locked. Export copies have unmanaged lifetime.
foreign import ccall unsafe "cometa_signing_key_data"
  cData :: Ptr NativeKey -> IO (Ptr Word8)

-- | Fixed-size length observer, without exporting key contents.
foreign import ccall unsafe "cometa_signing_key_size"
  cSize :: Ptr NativeKey -> IO CSize

-- | Writes exactly 32 public bytes on success. Temporary native output is scoped.
foreign import ccall safe "cometa_signing_key_public_key"
  cPublicKey :: Ptr NativeKey -> Ptr Word8 -> IO NativeCode

-- | Writes exactly 64 signature bytes on success; message storage stays alive for
-- the complete safe call. No user callback or Haskell pointer is retained.
foreign import ccall safe "cometa_signing_key_sign"
  cSign :: Ptr NativeKey -> Ptr Word8 -> CSize -> Ptr Word8 -> IO NativeCode
