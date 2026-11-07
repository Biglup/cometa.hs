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

-- | Callback-free conversion. Inputs are borrowed until return; a successful
-- output owns one buffer reference. The call may allocate proportionally to
-- cost-model size and uses the safe calling convention.
module Cometa.Internal.FFI.ParameterUpdate (cToPlutusData) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Cometa.Internal.FFI.Runtime (Buffer)
import Data.Word (Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_parameters_update_to_plutus_data"
  cToPlutusData :: Ptr Word8 -> CSize -> Ptr (Ptr Buffer) -> IO NativeCode
