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

-- | Private BIP32 ABI. All inputs are borrowed until return. Owned secret outputs
-- are initialized to NULL and adopted by the locked scope. Safe imports permit
-- scheduling through derivation; no call retains host buffers or runs callbacks.
module Cometa.Internal.FFI.Bip32
  ( NativeKey,
    cFromBytes,
    cFromHex,
    cFromEntropy,
    cClone,
    cDerive,
    cToSigningKey,
    cUnref,
    cData,
    cSize,
    cPublicKey,
    cDerivePublic,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import qualified Cometa.Internal.FFI.SigningKey as Signing
import Data.Word (Word32, Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- TYPES ----------------------------------------------------------------------

-- | Native secret allocation, accessible only under its scope lock.
data NativeKey

-- Fixed encoded sizes are 96 private / 64 public bytes, audited against
-- BIP32_ED25519_PRIVATE_KEY_LENGTH and BIP32_ED25519_PUBLIC_KEY_LENGTH in
-- lib/src/crypto/bip32_private_key.c and bip32_public_key.c at native/cardano-c.ref.
-- Public known answers and the scoped native size observer verify these sizes.

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_bip32_from_bytes"
  cFromBytes :: Ptr Word8 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_bip32_from_hex"
  cFromHex :: Ptr Word8 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_bip32_from_entropy"
  cFromEntropy :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_bip32_clone"
  cClone :: Ptr NativeKey -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_bip32_derive"
  cDerive :: Ptr NativeKey -> Ptr Word32 -> CSize -> Ptr (Ptr NativeKey) -> IO NativeCode

foreign import ccall safe "cometa_bip32_to_signing_key"
  cToSigningKey :: Ptr NativeKey -> Ptr (Ptr Signing.NativeKey) -> IO NativeCode

foreign import ccall unsafe "cometa_bip32_unref"
  cUnref :: Ptr (Ptr NativeKey) -> IO ()

foreign import ccall unsafe "cometa_bip32_data"
  cData :: Ptr NativeKey -> IO (Ptr Word8)

foreign import ccall unsafe "cometa_bip32_size"
  cSize :: Ptr NativeKey -> IO CSize

foreign import ccall safe "cometa_bip32_public_key"
  cPublicKey :: Ptr NativeKey -> Ptr Word8 -> IO NativeCode

foreign import ccall safe "cometa_bip32_derive_public"
  cDerivePublic :: Ptr Word8 -> Ptr Word32 -> CSize -> Ptr Word8 -> IO NativeCode
