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

-- | Hash a UTF-8 command-line message, or a small default message.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import System.Environment (getArgs)
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  arguments <- getArgs
  let message = case arguments of
        [] -> "Hello, Cardano!"
        _ -> unwords arguments

  version <- Cometa.nativeVersion
  Text.putStrLn (Text.pack "cardano-c " <> version)

  result <- Blake2b.compute 32 (Text.encodeUtf8 (Text.pack message))

  case result of
    Left failure -> die (show failure)
    Right digest -> Text.putStrLn (Blake2b.toHex digest)
