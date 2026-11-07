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

-- | Synchronous, callback-free native signing. Inputs remain borrowed until
-- return. Each output slot owns a buffer even if a later operation fails.
module Cometa.Internal.FFI.Cip8 (cSign) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Cometa.Internal.FFI.PasswordCrypto (Buffer)
import Cometa.Internal.FFI.SigningKey (NativeKey)
import Data.Word (Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_cip8_sign"
  cSign :: Ptr NativeKey -> CUInt -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> Ptr (Ptr Buffer) -> IO NativeCode
