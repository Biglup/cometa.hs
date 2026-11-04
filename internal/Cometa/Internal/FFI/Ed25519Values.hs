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

-- | Stateless Ed25519 value operations. The C adapter imports public bytes
-- into local native objects and releases them before returning. Status values
-- use an explicit unsigned C ABI, and Boolean output is converted to int.
-- The pinned native constructors use crypto_sign_PUBLICKEYBYTES (32) and
-- crypto_sign_BYTES (64) in lib/src/crypto/ed25519_public_key.c and
-- ed25519_signature.c. The pure public value constructors mirror those widths.
module Cometa.Internal.FFI.Ed25519Values (cVerify, cPublicKeyHash) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode, NativeHash)
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- FOREIGN IMPORTS ------------------------------------------------------------

-- | Borrow every input byte span for the complete synchronous operation.
-- Native false is represented by a successful status with output zero.
foreign import ccall safe "cometa_ed25519_verify"
  cVerify :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CInt -> IO NativeCode

-- | Return one owned hash reference, including any partial failure output.
-- The caller initializes its output slot and releases its own reference once.
foreign import ccall safe "cometa_ed25519_public_key_hash"
  cPublicKeyHash :: Ptr Word8 -> CSize -> Ptr (Ptr NativeHash) -> IO NativeCode
