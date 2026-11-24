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

-- | Terminal input for wallet secrets. Echo is restored even if reading fails.
module Support.Terminal (secret, password) where

import Control.Exception (bracket, finally)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import System.IO (hFlush, hGetEcho, hIsTerminalDevice, hSetEcho, stdin, stdout)

secret :: String -> IO Text
secret prompt = do
  terminal <- hIsTerminalDevice stdin
  unless terminal (ioError (userError "Wallet secrets require an interactive terminal"))
  bracket (hGetEcho stdin) (hSetEcho stdin) $ \_ -> do
    hSetEcho stdin False
    putStr prompt
    hFlush stdout
    Text.getLine `finally` putStrLn ""

password :: FilePath -> IO ByteString
password file = Text.encodeUtf8 <$> secret ("Password for " <> file <> ": ")
