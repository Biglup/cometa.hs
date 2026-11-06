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

-- | Calculate output and transaction costs without querying a provider.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    address <- except (Address.fromBytes (ByteString.cons 0x61 (ByteString.replicate 28 1)))
    output <- except (Output.mkOutput address (Value.lovelace 2000000) Datum.NoDatum Nothing)
    body <- except (Body.fromBody (Body.body [] [output] 0))

    -- Demonstration coefficients only; obtain current values from a provider.
    minimumCoin <- ExceptT (Building.minimumAda 4310 output)
    linearFee <- ExceptT (Building.baseFee 155381 44 (Tx.fromBody body))
    pure (minimumCoin, linearFee)

  case result of
    Left failure -> die (show failure)
    Right (minimumCoin, linearFee) -> do
      putStrLn ("Minimum output lovelace: " <> show minimumCoin)
      putStrLn ("Linear fee before adding witnesses: " <> show linearFee)
