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

-- | Synchronous native UPLC parameter marshaling. Inputs are borrowed until
-- return; the caller owns the output buffer even on partial failure. No callbacks
-- run. The safe non-interruptible import completes before cancellation unwinds
-- the caller's output scope, so no arena, list or output can escape cleanup.
module Cometa.Internal.FFI.Script (cApplyParams) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Cbor (NativeBuffer)
import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_script_apply_params"
  cApplyParams :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode
