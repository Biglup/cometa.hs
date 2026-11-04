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

-- | Encode and decode an integer using CBOR.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Encoding.Cbor as Cbor
import System.Exit (die)

-- DEFINITIONS ---------------------------------------------------------------

main :: IO ()
main = do
  encoded <- Cbor.encodeInteger 42

  case encoded of
    Left failure -> die (show failure)
    Right value -> do
      print (Cbor.toHex value)
      decoded <- Cbor.decodeInteger value

      case decoded of
        Left failure -> die (show failure)
        Right number -> print number
