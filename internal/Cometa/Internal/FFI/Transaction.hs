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

-- | Private snapshot adapter with explicit scalar C ABI. Input buffers are
-- borrowed through each safe call; successful outputs own one snapshot. Byte
-- observers borrow storage which must be copied before freeing the snapshot.
module Cometa.Internal.FFI.Transaction
  ( NativeSnapshot,
    cDecode,
    cSetFee,
    cFree,
    cBytes,
    cFee,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- TYPES ----------------------------------------------------------------------

-- | Opaque allocation; native references and byte buffers never escape its scope.
data NativeSnapshot

-- FOREIGN IMPORTS ------------------------------------------------------------

-- | Validate complete input, rejecting trailing bytes; return an owned snapshot.
-- Safe because decoding and copying scale with the input and may allocate.
foreign import ccall safe "cometa_transaction_decode"
  cDecode :: Ptr Word8 -> CSize -> Ptr (Ptr NativeSnapshot) -> IO NativeCode

-- | Decode and deep-clone, change the fee, invalidate body encoding and strip
-- outer key signatures. The source bytes are borrowed and remain unchanged.
foreign import ccall safe "cometa_transaction_set_fee"
  cSetFee :: Ptr Word8 -> CSize -> Word64 -> Ptr (Ptr NativeSnapshot) -> IO NativeCode

-- | Bounded snapshot destructor. Consumes the local reference and clears its slot.
foreign import ccall unsafe "cometa_transaction_snapshot_free"
  cFree :: Ptr (Ptr NativeSnapshot) -> IO ()

-- | Borrow bytes: private adapter fields 0 full, 1 body, 2 hash, 3 witnesses.
-- Writes the byte length; null storage or zero length is an invalid snapshot.
foreign import ccall unsafe "cometa_transaction_snapshot_bytes"
  cBytes :: Ptr NativeSnapshot -> CUInt -> Ptr CSize -> IO (Ptr Word8)

-- | Snapshotted fee in lovelace, using an explicit unsigned 64-bit ABI.
foreign import ccall unsafe "cometa_transaction_snapshot_fee"
  cFee :: Ptr NativeSnapshot -> IO Word64
