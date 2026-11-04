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

-- | Version information and shared operation errors. Import domain modules
-- qualified, for example @Cometa.Crypto.Blake2b@ as @Blake2b@.
--
-- @
-- import qualified Cometa
--
-- main :: IO ()
-- main = Cometa.nativeVersion >>= print
-- @
module Cometa
  ( -- * Version information
    nativeVersion,

    -- * Errors
    Error (..),
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.Native as Native
import Cometa.Internal.Ownership (copyStaticText)
import Data.Text (Text)

-- DEFINITIONS ----------------------------------------------------------------

-- | Return the version of cardano-c used by the running application. This is
-- independent of the Cometa.hs package version.
nativeVersion :: IO Text
nativeVersion = Native.cVersion >>= copyStaticText
