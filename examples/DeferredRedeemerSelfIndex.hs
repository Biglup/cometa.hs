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

import Cometa.Error (Error)
import qualified Cometa.Script as Script
import qualified Cometa.Transaction as Tx
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Support.Scripts as Scripts
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext (..))
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "DeferredRedeemerSelfIndex" deferredSelf

deferredSelf :: WalletContext -> IO (Either Error [Tx.Transaction])
deferredSelf wallet = runExceptT $ do
  script <- Script.Plutus <$> ExceptT Scripts.selfIndex
  ExceptT (Workflow.runDeferredSelf (context wallet) script)
