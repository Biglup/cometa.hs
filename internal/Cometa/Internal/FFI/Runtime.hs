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

-- | Generic adopted callback context and owned byte-buffer ABI. No native layout
-- crosses this boundary. Every callback-capable operation must use safe imports.
module Cometa.Internal.FFI.Runtime
  ( Context,
    Buffer,
    Callback,
    wrapCallback,
    cNew,
    cRef,
    cRelease,
    cBufferNew,
    cBufferRelease,
    cBufferData,
    cBufferSize,
    cLiveContexts,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word32, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (FunPtr, Ptr)
import Foreign.StablePtr (StablePtr)

-- TYPES ----------------------------------------------------------------------

data Context

data Buffer

-- | Request borrowed until callback return; success transfers one reply buffer.
-- Failure diagnostic is bounded and the original Error stays in Haskell state.
type Callback state = StablePtr state -> Word32 -> Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> CString -> CSize -> IO NativeCode

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall "wrapper"
  wrapCallback :: Callback state -> IO (FunPtr (Callback state))

foreign import ccall safe "cometa_runtime_new"
  cNew :: StablePtr state -> FunPtr (Callback state) -> Ptr (Ptr Context) -> IO NativeCode

foreign import ccall unsafe "cometa_runtime_ref"
  cRef :: Ptr Context -> IO ()

foreign import ccall safe "cometa_runtime_release"
  cRelease :: Ptr Context -> IO ()

foreign import ccall safe "cometa_runtime_buffer_new"
  cBufferNew :: Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> IO NativeCode

foreign import ccall safe "cometa_runtime_buffer_release"
  cBufferRelease :: Ptr (Ptr Buffer) -> IO ()

foreign import ccall unsafe "cometa_runtime_buffer_data"
  cBufferData :: Ptr Buffer -> IO (Ptr Word8)

foreign import ccall unsafe "cometa_runtime_buffer_size"
  cBufferSize :: Ptr Buffer -> IO CSize

foreign import ccall unsafe "cometa_runtime_live_contexts"
  cLiveContexts :: IO CSize
