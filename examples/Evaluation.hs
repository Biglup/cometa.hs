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

-- | Inject an offline evaluator and signer through one expected-error boundary.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.PlutusData as Data
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- Key.withNormalKey (ByteString.replicate 32 7) $ \key -> runExceptT $ do
    transaction <- except prepare
    budgets <- ExceptT (Evaluation.evaluate offlineEvaluator Evaluation.TopLevel transaction [])
    partial <- ExceptT (Signer.signTransaction (Signer.ed25519 key) transaction)
    signed <- except (Tx.addWitnesses partial transaction)
    pure (budgets, signed)
  case result of
    Left failure -> die (show failure)
    Right (budgets, signed) -> do
      putStrLn ("Requested budgets: " <> show (Evaluation.budgets budgets))
      putStrLn ("Partial signatures: " <> show (length (Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses signed)))))

prepare :: Either Error Tx.Transaction
prepare = do
  let argument = Data.fromData (Data.Constr 0 [])
      redeemer = Redeemer.Redeemer Redeemer.Spending 0 argument (ExUnits 0 0)
  witnesses <- Witnesses.mkWitnesses [] [] [] [] [redeemer]
  body <- Body.fromBody (Body.body [] [] 0)
  pure (Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing)

-- A deterministic application test double. Real implementations evaluate scripts
-- against resolved inputs and protocol context; this example uses no network.
offlineEvaluator :: Evaluation.Evaluator
offlineEvaluator = Evaluation.Evaluator $ \target transaction _ -> pure $ case target of
  Evaluation.SubTransaction _ -> Left (UnsupportedOperation "This example evaluates the outer transaction only")
  Evaluation.TopLevel ->
    Evaluation.mkBudgets
      [ (Evaluation.RedeemerId (Redeemer.purpose redeemer) (Redeemer.index redeemer), ExUnits 1000000 100000000)
      | redeemer <- Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses transaction))
      ]
