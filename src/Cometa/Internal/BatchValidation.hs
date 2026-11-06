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
{-# OPTIONS_HADDOCK hide #-}

-- | Verify declared intent budgets in the completed enclosing context without
-- mutating signed bodies. Each evaluator request remains operation-scoped.
module Cometa.Internal.BatchValidation (validateSubBudgets) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Protocol.ExUnits as Ex
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)

-- DEFINITIONS ----------------------------------------------------------------

validateSubBudgets :: Evaluation.Evaluator -> [Utxo.Utxo] -> Tx.Transaction -> IO (Either Error ())
validateSubBudgets evaluator resolved transaction =
  runExceptT $
    mapM_ check (zip [0 ..] subs)
  where
    subs = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
    check (index, intent) = do
      let redeemers = Witnesses.redeemers (Witnesses.toWitnesses (Sub.witnesses intent))
          declared = Map.fromList [(Evaluation.RedeemerId (Redeemer.purpose value) (Redeemer.index value), Redeemer.executionUnits value) | value <- redeemers]
      unless (null redeemers) $ do
        actual <- ExceptT (Evaluation.evaluate evaluator (Evaluation.SubTransaction index) transaction resolved)
        except (mapM_ (within declared) (Evaluation.budgets actual))
    within declared (identifier, actual) = case Map.lookup identifier declared of
      Nothing -> Left (InvalidEvaluationResult "Subtransaction evaluation returned an unknown redeemer")
      Just limit ->
        unless
          (Ex.memory actual <= Ex.memory limit && Ex.steps actual <= Ex.steps limit)
          (Left (InvalidBuildingRequest "Attached subtransaction execution exceeds its declared budget"))
