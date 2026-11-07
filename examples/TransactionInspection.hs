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

-- | Inspect a synthetic transaction without network access or private keys.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.PlutusData as Data
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Inspection as Inspection
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy.Char8 as Lazy
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    body <- except (Body.fromBody (Body.body [] [] 170000))
    let datum = Data.fromData (Data.List [Data.Integer 42, Data.Bytes (Bytes.pack [0, 255])])
    witnesses <- except (Witnesses.mkWitnesses [] [] [] [datum] [])
    let transaction = Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing
    ExceptT (Inspection.transaction transaction)

  case result of
    Left failure -> die (show failure)
    Right value -> Lazy.putStrLn (Aeson.encode value)
