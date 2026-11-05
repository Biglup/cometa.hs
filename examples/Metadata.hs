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

-- | Offline metadata assembly, reload and explicit normalization.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error)
import qualified Cometa.Metadata as Metadata
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT workflow
  case result of
    Left failure -> die (show failure)
    Right (metadata, digest) -> do
      print (Metadata.toList metadata)
      putStrLn ("Metadata encoding digest: " ++ show (Blake2b.toHex digest))

workflow :: ExceptT Error IO (Metadata.Metadata, Blake2b.Blake2bHash)
workflow = do
  message <- except (Metadata.mkText "Hello from Cometa")
  key <- except (Metadata.mkText "msg")
  let metadata = Metadata.singleton 674 (Metadata.map [(key, Metadata.list [message])])
      bytes = Metadata.encodeCbor metadata

  -- A stored or received encoding is validated once on import.
  imported <- except (Metadata.decodeCbor bytes)
  digest <- ExceptT (Blake2b.compute 32 (Metadata.toCbor imported))
  pure (Metadata.toMetadata imported, digest)
