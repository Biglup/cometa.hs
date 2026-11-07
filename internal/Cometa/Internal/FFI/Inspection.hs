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

-- | Callback-free native inspection of a fresh CBOR snapshot. The input borrows
-- through return and the result buffer transfers to the ordinary owned scope.
module Cometa.Internal.FFI.Inspection (cCompute) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Cometa.Internal.FFI.Runtime (Buffer)
import Data.Word (Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_inspection_compute"
  cCompute :: CUInt -> Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> IO NativeCode
