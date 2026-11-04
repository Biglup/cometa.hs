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
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.DerivationPath as Path

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = case Path.mkIndex 0 of
  Left err -> print err
  Right zero -> do
    let account = Path.mkStandardAccountPath zero
        payment = Path.mkDerivationPath account Path.externalRole zero

    print (Path.accountIndices account)
    print (Path.toIndices payment)
    print (Path.relativeIndices payment)
