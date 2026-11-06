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

-- | Callback-capable fresh native builder operation. Both contexts and byte
-- buffers borrow through return; transaction and diagnostic buffers transfer.
module Cometa.Internal.FFI.TransactionBuilder (cBuild) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Cometa.Internal.FFI.Runtime (Buffer, Context)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

foreign import ccall safe "cometa_transaction_builder_build"
  cBuild :: Ptr Context -> Ptr Context -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> Ptr (Ptr Buffer) -> Ptr Word64 -> IO NativeCode
