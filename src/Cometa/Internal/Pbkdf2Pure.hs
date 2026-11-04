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
{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Concrete purity exception for the separately audited pinned PBKDF2 path.
-- Caller-owned scratch is the only mutable output. Neither native configured
-- allocation, RNG, global state, callbacks nor logging is reached. See
-- docs/development/PBKDF2_PURITY.md. Never generalize to an arbitrary IO runner.
module Cometa.Internal.Pbkdf2Pure (deriveBytes) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.PasswordCrypto as Internal
import Control.Exception (evaluate)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Data.Word (Word32)
import System.IO.Unsafe (unsafePerformIO)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validated inputs only. Force the strict owned result and any diagnostic
-- before returning from this boundary; repeated evaluation is equivalent.
{-# NOINLINE deriveBytes #-}
deriveBytes :: ByteString -> ByteString -> Word32 -> Int -> Either Error ByteString
deriveBytes password salt iterations size = unsafePerformIO $ do
  result <- either (Left . fromNativeFailure) Right <$> Internal.deriveBytes password salt iterations size
  evaluate (forceResult result)
  pure result

forceResult :: Either Error ByteString -> ()
forceResult (Right bytes) = ByteString.length bytes `seq` ()
forceResult (Left (NativeError operation code diagnostic)) =
  Text.length operation `seq` Code.toNumber code `seq` Text.length diagnostic `seq` ()
forceResult (Left (NativeContractViolation operation)) = Text.length operation `seq` ()
forceResult (Left err) = err `seq` ()
