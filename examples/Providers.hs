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

-- | Query an offline backend using the same types as a connected provider.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import Cometa.Error (Error)
import qualified Cometa.Provider as Provider
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- queryFixture
  case result of
    Left failure -> die (show failure)
    Right count -> putStrLn ("Unspent outputs: " <> show count)

queryFixture :: IO (Either Error Int)
queryFixture = runExceptT $ do
  -- Deterministic address bytes only; no keys, credentials or network connection.
  address <- except (Address.fromBytes (ByteString.cons 0x61 (ByteString.replicate 28 1)))

  let provider =
        (Provider.unavailable "Offline fixture" 42)
          { Provider.utxosAt = \_ -> pure (Right [])
          }

  outputs <- ExceptT (Provider.utxosAt provider address)
  pure (length outputs)
