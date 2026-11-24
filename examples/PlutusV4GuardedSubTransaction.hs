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

module Main (main) where

import Cometa.Error (Error (..))
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Provider as Provider
import qualified Cometa.Script as Script
import qualified Cometa.Transaction as Tx
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import qualified Support.Scripts as Scripts
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext (..))
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "PlutusV4GuardedSubTransaction" guardedSub

guardedSub :: WalletContext -> IO (Either Error [Tx.Transaction])
guardedSub wallet = runExceptT $ do
  params <- ExceptT (Provider.protocolParameters (Workflow.provider (context wallet)))
  let Version.ProtocolVersion major _ = Parameters.parameterProtocolVersion params
  unless (major >= 12) (throwE (InvalidBuildingRequest "Guarded subtransactions require protocol 12 or later"))
  validator <- Script.Plutus <$> ExceptT Scripts.v4Validator
  guard <- Script.Plutus <$> ExceptT Scripts.v4Guard
  ExceptT (Workflow.runGuardedSub (context wallet) validator guard (signSubTransaction wallet))
