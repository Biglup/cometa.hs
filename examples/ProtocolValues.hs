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

-- | Exact execution fee calculation and offline price reload.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as ExUnits
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.UnitInterval as Unit
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = case workflow of
  Left failure -> die (show failure)
  Right (fee, threshold) -> do
    putStrLn ("Execution fee in lovelace: " ++ show fee)
    putStrLn ("Voting approval proportion: " ++ show (Unit.toRational threshold))

workflow :: Either Error (Integer, Unit.UnitInterval)
workflow = do
  memoryPrice <- Rational.mkNonNegativeRational 577 10000
  stepPrice <- Rational.mkNonNegativeRational 721 10000000
  threshold <- Unit.mkUnitInterval 2 3
  let prices = Prices.ExUnitPrices memoryPrice stepPrice
      budget = ExUnits.ExUnits 14000000 10000000000

  reloaded <- Prices.decodeCbor (Prices.encodeCbor prices)
  let exactFee =
        Rational.toRational (Prices.memoryPrice reloaded) * fromIntegral (ExUnits.memory budget)
          + Rational.toRational (Prices.stepPrice reloaded) * fromIntegral (ExUnits.steps budget)
  pure (ceiling exactFee, threshold)
