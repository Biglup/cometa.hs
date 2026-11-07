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

-- | Assemble a sparse fee change, serialize it, and inspect a validated import.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.Parameters.Update as Update
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- | Print the encoded size of a validated fee change, or fail with its error.
main :: IO ()
main = do
  result <- workflow
  case result of
    Left failure -> die (show failure)
    Right (bytes, scriptData) -> do
      putStrLn ("Validated protocol update: " <> show (ByteString.length bytes) <> " CBOR bytes")
      print scriptData

workflow :: IO (Either Error (ByteString.ByteString, Data.PlutusData))
workflow = runExceptT $ do
  let change = Update.empty {Update.updateMinFeeA = Just 44, Update.updateMinFeeB = Just 155381}
      bytes = Update.encodeCbor change
  imported <- except (Update.decodeCbor bytes)
  scriptData <- ExceptT (Update.toPlutusData change)
  -- Preserve the exact validated bytes when attaching an imported proposal.
  pure (Update.toCbor imported, scriptData)
