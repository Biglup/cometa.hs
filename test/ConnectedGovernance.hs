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

-- | Offline execution of the same recipes used by the connected C++ ports.
-- Fixture conservation/signature checks do not establish ledger registration state.
module ConnectedGovernance (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.NetworkId as Network
import qualified Cometa.Script as Script
import qualified Cometa.Transaction as Transaction
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TransactionId
import qualified Cometa.Value as Value
import qualified Connected.Governance as Governance
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)
import qualified Workflows.Fixture as Fixture
import qualified Workflows.Native as Native
import qualified Workflows.NativeScripts as Scripts

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Connected governance recipes"
    [ testCase "key reward registration and cleanup" (execute 2 $ \context fixture -> pool >>= Governance.rewardKey context (Fixture.stakeCredential fixture)),
      testCase "V2 reward registration and cleanup" (execute 2 $ \context _ -> pool >>= Governance.rewardScript context),
      testCase "canonical deferred zero withdrawal" (execute 2 $ \context _ -> pool >>= Governance.withdrawZero context),
      testCase "key DRep delegation and both cleanups" (execute 4 $ \context fixture -> Governance.drepKey context (Fixture.drepCredential fixture) (Fixture.stakeCredential fixture)),
      testCase "reference-sourced V3 DRep delegation and both cleanups" (execute 4 $ \context fixture -> reference context >>= \source -> Governance.drepScript context source (Fixture.stakeCredential fixture)),
      testCase "key DRep vote and cleanup" (execute 3 $ \context fixture -> action >>= Governance.voteKey context (Fixture.drepCredential fixture)),
      testCase "V3 DRep vote and cleanup" (execute 3 $ \context _ -> do source <- reference context; proposal <- action; Governance.voteScript context source proposal),
      testCase "two ADA donation" (execute 1 $ \context _ -> Governance.donate context),
      testCase "treasury proposal preserves reference input" treasury,
      testCase "wrong constitution hash fails before submission" wrongHash,
      testCase "public script discovery has both reward identities" discovery
    ]

pool :: IO (Credential.KeyHash Credential.StakePool)
pool = must (Credential.keyHashFromBytes (B.replicate 28 10))

action :: IO ActionId.ActionId
action = do
  identifier <- must (TransactionId.fromBytes (B.replicate 32 11))
  pure (ActionId.ActionId identifier 0)

-- This reference is used only as a resolved source of the exact compiled V3
-- program, matching the C++ DRep/vote examples' addScript workflow.
reference :: Native.Context -> IO Utxo.Utxo
reference context = do
  script <- Scripts.alwaysSucceedsV3 >>= must
  output <- must (Output.mkOutput (Native.wallet context) (Value.lovelace 30000000) Datum.NoDatum (Just (Script.Plutus script)))
  identifier <- must (TransactionId.fromBytes (B.replicate 32 12))
  pure (Utxo.utxo (Input.input identifier 0) output)

execute :: Int -> (Native.Context -> Fixture.Fixture -> IO (Either Error [Transaction.Transaction])) -> IO ()
execute expected operation = do
  result <- Fixture.withFixture $ \context fixture -> runExceptT $ do
    _ <- ExceptT (operation context fixture)
    history <- ExceptT (Right <$> Fixture.submitted fixture)
    except (unless (length history == expected) (Left (InvalidBuildingRequest "Unexpected connected workflow stage count")))
  _ <- must result
  pure ()

treasury :: IO ()
treasury = execute 2 $ \context fixture -> runExceptT $ do
  source <- ExceptT (Right <$> reference context)
  funded <- ExceptT (Native.runStage context (Plan.payTo (Utxo.output source)))
  identifier <- ExceptT (Transaction.transactionId funded)
  let actual = Utxo.utxo (Input.input identifier 0) (Utxo.output source)
      account = Reward.fromCredential Network.testnet (Fixture.stakeCredential fixture)
  script <- except (maybe (Left (InvalidBuildingRequest "Missing reference script")) Right (Output.referenceScript (Utxo.output actual)))
  hash <- ExceptT (Script.hash script)
  submitted <- ExceptT (Governance.treasury context account actual hash 1000)
  except $ case submitted of
    [transaction] -> unless (Fields.fieldReferenceInputs (Body.bodyFields (Body.toBody (Transaction.body transaction))) == Just [Utxo.input actual]) (Left (InvalidBuildingRequest "Constitution reference input was not preserved"))
    _ -> Left (InvalidBuildingRequest "Expected exactly one proposal")
  pure submitted

wrongHash :: IO ()
wrongHash = do
  result <- Fixture.withFixture $ \context fixture -> do
    source <- reference context
    hash <- must (Credential.scriptHashFromBytes (B.replicate 28 0))
    attempt <- Governance.treasury context (Reward.fromCredential Network.testnet (Fixture.stakeCredential fixture)) source hash 1000
    history <- Fixture.submitted fixture
    pure (Right (isLeft attempt && null history))
  must result >>= assertBool "mismatched constitution must fail before submission"

discovery :: IO ()
discovery = do
  identities <- Governance.describeScripts Network.testnet >>= must
  accounts <- must (traverse (Reward.fromText . snd) identities)
  assertBool "both script accounts" (map fst identities == ["reward-script", "withdraw-zero-script"] && not (any (B.null . Reward.toBytes) accounts))

must :: (Show failure) => Either failure value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure
