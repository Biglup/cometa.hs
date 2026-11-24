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

import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Support.Governance as Governance
import qualified Support.Inputs as Inputs
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypointWithDescription "ProposeTreasuryWithdrawal" (Inputs.describe (Just "COMETA_CONSTITUTION_REFERENCE")) $ \wallet -> runExceptT $ do
  let context = Support.context wallet
  reference <- ExceptT (Support.resolveReference context "COMETA_CONSTITUTION_REFERENCE")
  (reward, hash, amount) <- ExceptT Inputs.treasurySettings
  ExceptT (Governance.treasury context reward reference hash amount)
