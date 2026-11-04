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

-- | Password-based key derivation using PBKDF2-HMAC-SHA512. Inputs are raw bytes;
-- no text encoding or normalization is applied. This module deliberately exports
-- secret bytes: callers control their lifetime and must avoid logging them.
--
-- @
-- import qualified Cometa.Crypto.Pbkdf2 as Pbkdf2
-- -- Deterministic example data only; choose cost and salt for your application.
-- derive password salt = Pbkdf2.deriveBytes password salt 100000 32
-- @
module Cometa.Crypto.Pbkdf2 (deriveBytes) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Internal.Pbkdf2Pure as Internal
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString

-- DEFINITIONS ----------------------------------------------------------------

-- | Explicitly derive and export secret bytes from password, salt, iteration
-- count and output byte count, in that order. Password may be empty or contain
-- NUL; salt must be nonempty. Iterations must be @1..4294967295@. Output must be
-- @1..min(maxBound :: Int, 64 * (2^32 - 1))@ bytes, the PBKDF2 block limit.
-- Invalid inputs return 'EmptyPbkdf2Salt', 'InvalidPbkdf2Iterations' or
-- 'InvalidPbkdf2OutputLength' before derivation. Other failures return
-- 'NativeError'; allocation exceptions propagate. No default cost is chosen.
-- Large requests can require substantial memory and computation. Cancellation
-- waits for the ongoing derivation and cleanup. Input and returned Haskell
-- bytes are not erased by this operation.
deriveBytes :: ByteString -> ByteString -> Integer -> Integer -> Either Error ByteString
deriveBytes password salt iterations size
  | ByteString.null salt = Left EmptyPbkdf2Salt
  | iterations < 1 || iterations > 4294967295 = Left (InvalidPbkdf2Iterations iterations)
  | size < 1 || size > min (toInteger (maxBound :: Int)) (64 * (2 ^ (32 :: Int) - 1)) = Left (InvalidPbkdf2OutputLength size)
  | otherwise = Internal.deriveBytes password salt (fromInteger iterations) (fromInteger size)
