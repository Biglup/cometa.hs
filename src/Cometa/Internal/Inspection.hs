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

-- | Fresh native inspection results copied before releasing their buffer. The
-- existing owned-buffer runner preserves native status and cleans partial output
-- on normal return, native failure and asynchronous unwind.
module Cometa.Internal.Inspection (inspect, runUnchecked) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.Inspection as FFI
import qualified Cometa.Internal.Runtime as Runtime
import Data.Aeson (Value, eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.Text (Text)
import Foreign.C.Types (CUInt)

-- DEFINITIONS ----------------------------------------------------------------

inspect :: Text -> CUInt -> ByteString -> IO (Either Error Value)
inspect operation kind bytes = do
  result <- runUnchecked kind bytes
  pure $ do
    json <- result
    either (const (Left (NativeContractViolation operation))) Right (eitherDecodeStrict' json)

-- | Private malformed-CBOR/operation transport for error and cleanup tests. All
-- native owners still remain scoped through safe foreign return before copying.
runUnchecked :: CUInt -> ByteString -> IO (Either Error ByteString)
runUnchecked kind bytes = Runtime.withBytes bytes $ \input size ->
  Runtime.withOwnedBuffer "inspection.compute" (FFI.cCompute kind input size)
