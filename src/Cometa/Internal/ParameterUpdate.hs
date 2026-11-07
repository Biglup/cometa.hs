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
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Convert one complete update using operation-scoped native owners. The
-- result is copied before release, including on cancellation and decode failure.
module Cometa.Internal.ParameterUpdate (toPlutusData) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.Internal.FFI.ParameterUpdate as FFI
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.PlutusData as Data
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

toPlutusData :: ByteString -> IO (Either Error Data.PlutusData)
toPlutusData encoded = Runtime.withBytes encoded $ \bytes size -> do
  result <- Runtime.withOwnedBuffer "parameters.toPlutusData" (FFI.cToPlutusData bytes size)
  pure (result >>= fmap Data.toData . Data.decodeCbor)
