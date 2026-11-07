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

-- | Validate asset identifiers, compose signed balances, and display a CIP-14 fingerprint.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import Cometa.Error (Error)
import qualified Cometa.PolicyId as PolicyId
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.Text as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    (token, remaining) <- except balances
    assetHex <- except (AssetId.toHex token)
    displayFingerprint <- ExceptT (AssetId.fingerprint token)
    pure (token, remaining, assetHex, displayFingerprint)

  case result of
    Left err -> die (show err)
    Right (token, remaining, assetHex, displayFingerprint) -> do
      putStrLn ("Asset ID: " <> Text.unpack assetHex)
      putStrLn ("Asset fingerprint: " <> Text.unpack displayFingerprint)
      putStrLn ("Remaining lovelace: " <> show (Value.quantity AssetId.Ada remaining))
      putStrLn ("Remaining token units: " <> show (Value.quantity token remaining))

balances :: Either Error (AssetId.AssetId, Value.Value)
balances = do
  policy <- PolicyId.fromHex (Text.replicate 28 "00")
  name <- AssetName.fromText "Token"

  let token = AssetId.Native policy name
      available = Value.fromList [(AssetId.Ada, 10000000), (token, 20)]
      payment = Value.lovelace 2000000 <> Value.singleton token 3
      remaining = Value.difference available payment

  pure (token, remaining)
