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
{-# OPTIONS_HADDOCK hide #-}

-- | Operation-scoped native re-encoding. The input span is borrowed through
-- safe foreign return; every parsed owner/writer is released by C. Runtime's
-- owned-buffer scope copies results and releases partial outputs on all exits.
module Cometa.Internal.Reencode (reencode) where

import Cometa.Error (Error)
import qualified Cometa.Internal.FFI.Reencode as FFI
import qualified Cometa.Internal.Runtime as Runtime
import Data.ByteString (ByteString)
import Data.Text (Text)
import Foreign.C.Types (CUInt)

reencode :: Text -> CUInt -> ByteString -> IO (Either Error ByteString)
reencode operation kind bytes = Runtime.withBytes bytes $ \input size -> Runtime.withOwnedBuffer operation (FFI.cReencode kind input size)
