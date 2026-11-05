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

-- | Build a datum, preserve its stored representation, then hash those bytes.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error)
import qualified Cometa.PlutusData as Data
import qualified Data.ByteString as ByteString

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  let datum = Data.Constr 0 [Data.Integer 42, Data.Map [(Data.Bytes ByteString.empty, Data.List [])]]
      stored = Data.encodeCbor datum
  result <- workflow stored
  either print (print . Blake2b.toHex) result

workflow :: ByteString.ByteString -> IO (Either Error Blake2b.Blake2bHash)
workflow stored = case Data.decodeCbor stored of
  Left failure -> pure (Left failure)
  Right datum -> Data.hash datum
