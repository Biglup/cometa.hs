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

module Main (main) where

import qualified Cometa.Crypto.Emip3 as Emip3
import qualified Cometa.Crypto.Pbkdf2 as Pbkdf2
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- Public deterministic sample material only. Do not print secrets.
main :: IO ()
main = case Pbkdf2.deriveBytes "sample password" "application salt" 10000 32 of
  Left err -> die (show err)
  Right derived -> do
    encrypted <- Emip3.encrypt "storage password" derived
    case encrypted of
      Left err -> die (show err)
      Right envelope -> do
        decrypted <- Emip3.decryptBytes "storage password" envelope
        case decrypted of
          Left err -> die (show err)
          Right restored
            | restored == derived -> putStrLn ("Recovered " ++ show (ByteString.length restored) ++ " bytes")
            | otherwise -> die "Recovered data differs"
