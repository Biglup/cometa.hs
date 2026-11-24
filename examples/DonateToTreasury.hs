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

module DonateToTreasury (main, donate) where

import Cometa.Error (Error (..))
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Plan as Plan
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import qualified Support.Transaction as Workflow
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "DonateToTreasury" (donate . Support.context)

donate :: Workflow.Context -> IO (Either Error [Tx.Transaction])
donate ctx = fmap (fmap pure) (submitPlan ctx (Plan.donate 2000000))

submitPlan :: Workflow.Context -> Plan.Plan -> IO (Either Error Tx.Transaction)
submitPlan ctx plan = runExceptT $ do
  settings <- ExceptT (Workflow.builderConfig ctx)
  unsigned <- ExceptT (Builder.build settings (plan <> Plan.validUntil (Workflow.invalidAfter ctx)))
  witnesses <- ExceptT (Signer.signTransaction (Workflow.signer ctx) unsigned)
  signed <- except (Tx.addWitnesses witnesses unsigned)
  expected <- ExceptT (Tx.transactionId signed)
  accepted <- ExceptT (Provider.submitTransaction (Workflow.provider ctx) signed)
  unless (accepted == expected) (throwE (InvalidProviderResponse "Submitted transaction ID mismatch"))
  confirmed <- ExceptT (Provider.awaitTransaction (Workflow.provider ctx) accepted (Workflow.confirmationTimeoutMillis ctx))
  unless confirmed (throwE (InvalidBuildingRequest "Transaction confirmation timed out"))
  ExceptT (Workflow.awaitWallet ctx signed)
  pure signed
