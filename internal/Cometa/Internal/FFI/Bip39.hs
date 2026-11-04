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

-- | Private BIP39 ABI. Inputs are borrowed only for each bounded call. Returned
-- word pointers refer to static English strings: copy them, never free them.
-- Entropy output belongs to the caller and can be written even on checksum
-- failure. No function allocates an owner, retains buffers, or invokes callbacks.
module Cometa.Internal.FFI.Bip39 (cFromEntropy, cToEntropy, cClear) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_bip39_from_entropy"
  cFromEntropy :: Ptr Word8 -> CSize -> Ptr CString -> Ptr CSize -> IO NativeCode

foreign import ccall safe "cometa_bip39_to_entropy"
  cToEntropy :: Ptr CString -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO NativeCode

-- | Bounded scratch-buffer wipe; must run after native use and host copying,
-- including exceptions and failure after native output has been written.
foreign import capi unsafe "cardano/cardano.h cardano_memzero"
  cClear :: Ptr Word8 -> CSize -> IO ()
