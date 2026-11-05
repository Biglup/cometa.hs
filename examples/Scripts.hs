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

-- | Assemble a timed native policy and parameterize a compiled Plutus program.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as PolicyId
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT scriptPolicies
  case result of
    Left failure -> die (show failure)
    Right (nativePolicy, plutusPolicy) -> do
      Text.putStrLn (PolicyId.toHex nativePolicy)
      Text.putStrLn (PolicyId.toHex plutusPolicy)

scriptPolicies :: ExceptT Error IO (PolicyId.PolicyId, PolicyId.PolicyId)
scriptPolicies = do
  -- Demonstration hash only: this example has no signing key or network access.
  key <- except (Credential.keyHashFromBytes (ByteString.replicate 28 0))
  let native = Native.allOf [Native.signature key, Native.invalidBefore 100, Native.invalidAfter 200]
  nativeHash <- ExceptT (Native.hash native)

  -- Single-CBOR-wrapped Flat identity program, before applying a data constant.
  compiled <- except (Plutus.fromBytes Plutus.V3 (ByteString.pack [0x45, 1, 0, 0, 0x24, 0x99]))
  applied <- ExceptT (Plutus.applyParams compiled [Data.Integer 42])
  plutusHash <- ExceptT (Plutus.hash applied)

  pure (PolicyId.fromScriptHash nativeHash, PolicyId.fromScriptHash plutusHash)
