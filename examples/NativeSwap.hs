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

-- | Offline buyer/seller token exchange with a separate fee-paying batcher.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Transaction as Tx
import qualified Cometa.TransactionId as Id
import qualified Data.Text.IO as Text
import System.Exit (die)
import qualified Workflows.Swap as Swap

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- Swap.runSwap
  case result of
    Left failure -> die (show failure)
    Right swap -> do
      identifier <- Tx.transactionId (Swap.transaction swap)
      either (die . show) (Text.putStrLn . Id.toHex) identifier
