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

-- | Evaluation result validation shared by public injection and native adapters.
-- No native resources are acquired here. Exact redeemer arguments never come
-- from an evaluator result; they are copied from the selected transaction level.
module Cometa.Internal.Evaluation
  ( Target (..),
    RedeemerId (..),
    Budgets,
    mkBudgets,
    budgets,
    Evaluator (..),
    evaluate,
    targetRedeemers,
    validateRequest,
    checkedRedeemers,
    budgetsFromRedeemers,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Protocol.ExUnits (ExUnits)
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad (foldM_, unless)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word32, Word64)

-- TYPES ----------------------------------------------------------------------

-- | Transaction level whose execution budgets are requested. A sub-transaction
-- evaluator still receives the complete enclosing transaction and resolved UTxOs.
data Target
  = -- | Redeemers in the outer transaction witness set.
    TopLevel
  | -- | Zero-based serialized position in the body's sub-transaction list.
    SubTransaction !Word64
  deriving (Eq, Ord, Show)

-- | A redeemer's purpose and zero-based index in its corresponding body field.
-- The index is bounded by 2^32-1, matching serializable redeemer identifiers.
data RedeemerId = RedeemerId !Redeemer.Purpose !Word32 deriving (Eq, Ord, Show)

-- | Unique sorted execution budgets. Equality compares identifiers and both
-- budget components. No script argument or transaction bytes occur in a result.
newtype Budgets = Budgets [(RedeemerId, ExUnits)] deriving (Eq, Show)

-- | An application-supplied evaluator. Expected failures use 'Either'; thrown
-- exceptions retain ordinary IO behavior. It receives the complete immutable
-- transaction and caller-supplied resolved UTxO snapshot. Implementations must
-- return exactly one budget for each redeemer at the requested level.
newtype Evaluator = Evaluator
  { -- | Perform evaluation without installing budgets or changing the input.
    -- Use 'evaluate' to check target, resolution and result correspondence.
    evaluateTransaction :: Target -> Tx.Transaction -> [Utxo.Utxo] -> IO (Either Error Budgets)
  }

-- DEFINITIONS ----------------------------------------------------------------

-- | Reject duplicate identifiers, then sort by purpose and index. Budgets contain
-- unsigned 64-bit memory units and CPU steps; this does not run a script.
mkBudgets :: [(RedeemerId, ExUnits)] -> Either Error Budgets
mkBudgets values = do
  let sorted = List.sortOn fst values
  unless (length sorted == Map.size (Map.fromList sorted)) (Left (InvalidEvaluationResult "Duplicate redeemer budget identifier"))
  pure (Budgets sorted)

-- | Budgets in ascending purpose/index order.
budgets :: Budgets -> [(RedeemerId, ExUnits)]
budgets (Budgets values) = values

-- | Validate the target and resolved-input uniqueness, call the injected
-- evaluator, and require complete identifier correspondence. Missing or unknown
-- identifiers return 'InvalidEvaluationResult'. Duplicate resolved references
-- return 'InvalidEvaluationRequest'. This neither checks chain freshness nor
-- requires all spending/reference inputs to resolve; that is evaluator-specific.
-- No body, script argument, witness or commitment is modified.
evaluate :: Evaluator -> Target -> Tx.Transaction -> [Utxo.Utxo] -> IO (Either Error Budgets)
evaluate evaluator target transaction resolved = case validateRequest target transaction resolved of
  Left failure -> pure (Left failure)
  Right () -> do
    result <- evaluateTransaction evaluator target transaction resolved
    pure $ do
      value <- result
      _ <- checkedRedeemers target transaction value
      pure value

validateRequest :: Target -> Tx.Transaction -> [Utxo.Utxo] -> Either Error ()
validateRequest target transaction resolved = do
  _ <- targetRedeemers target transaction
  foldM_ insert Map.empty resolved
  where
    insert values value
      | Map.member (Utxo.input value) values = Left (InvalidEvaluationRequest "Duplicate resolved input reference")
      | otherwise = Right (Map.insert (Utxo.input value) value values)

targetRedeemers :: Target -> Tx.Transaction -> Either Error [Redeemer.Redeemer]
targetRedeemers target transaction = case target of
  TopLevel -> Right (Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses transaction)))
  SubTransaction index -> case dropInteger (toInteger index) subs of
    [] -> Left (InvalidEvaluationRequest "Sub-transaction target is out of range")
    selected : _ -> Right (Witnesses.redeemers (Witnesses.toWitnesses (Sub.witnesses selected)))
  where
    subs = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
    dropInteger 0 values = values
    dropInteger _ [] = []
    dropInteger count (_ : rest) = dropInteger (count - 1) rest

identifier :: Redeemer.Redeemer -> RedeemerId
identifier value = RedeemerId (Redeemer.purpose value) (Redeemer.index value)

checkedRedeemers :: Target -> Tx.Transaction -> Budgets -> Either Error [Redeemer.Redeemer]
checkedRedeemers target transaction computed = do
  expected <- targetRedeemers target transaction
  let requested = Map.fromList [(identifier r, r) | r <- expected]
      returned = Map.fromList (budgets computed)
  unless (Map.keys requested == Map.keys returned) (Left (InvalidEvaluationResult "Missing or unknown redeemer budget identifiers"))
  traverse (replace returned) expected
  where
    replace values original = case Map.lookup (identifier original) values of
      Nothing -> Left (InvalidEvaluationResult "Missing redeemer budget identifier")
      Just units -> Right original {Redeemer.executionUnits = units}

budgetsFromRedeemers :: Target -> Tx.Transaction -> [Redeemer.Redeemer] -> Either Error Budgets
budgetsFromRedeemers target transaction returned = do
  computed <- mkBudgets [(identifier r, Redeemer.executionUnits r) | r <- returned]
  expected <- checkedRedeemers target transaction computed
  let ordered = List.sortOn identifier returned
  unless (ordered == List.sortOn identifier expected) (Left (InvalidEvaluationResult "Evaluator changed exact redeemer arguments"))
  pure computed
