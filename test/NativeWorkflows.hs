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
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Complete native-example flows with actual native building/VM/signing and
-- an in-memory provider. The provider is not a consensus ledger emulator.
module NativeWorkflows (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import Cometa.Error (Error (..))
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.Provider as Provider
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Signer as Signer
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Builder as SubBuilder
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (find)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import qualified Workflows.Fixture as Fixture
import qualified Workflows.Native as Workflow
import qualified Workflows.NativeScripts as Scripts
import qualified Workflows.Swap as Swap

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Native end-to-end examples"
    [ testCase "payment queries, signs, submits and confirms" payment,
      testCase "native mint then burn" nativeMint,
      testCase "Plutus mint then burn" plutusMint,
      testCase "native script funding then spend" nativeSpend,
      testCase "validator reference-script funding then spend" plutusSpend,
      testCase "actual Aiken self index and order pairing" deferredSpends,
      testCase "actual self-index validator rejects a wrong index" invalidIndex,
      testCase "key reward account registration and cleanup" keyRewards,
      testCase "script reward account registration and cleanup" scriptRewards,
      testCase "zero withdrawal forwards canonical input indices" withdrawZero,
      testCase "key and script DRep lifecycles" dreps,
      testCase "key and script governance voting lifecycles" votes,
      testCase "treasury withdrawal policy and donation" treasury,
      testCase "signed local intent reaches a complete batch" batch,
      testCase "buyer/seller token exchange preserves both independent signatures" swap,
      testCase "actual V4 validator and guard compose in a signed batch" guardedBatch,
      testCase "confirmation timeout prevents dependent stages" confirmation,
      testCase "confirmed wallet indexing waits for created and consumed outputs" indexLag,
      testCase "wallet indexing timeout stops without resubmitting" indexTimeout,
      testCase "invalid signatures refuse fixture submission without changing state" invalidSignature
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

execute :: Int -> (Workflow.Context -> Fixture.Fixture -> IO (Either Error a)) -> IO ()
execute expected action = do
  result <- Fixture.withFixture $ \context fixture -> runExceptT $ do
    _ <- ExceptT (action context fixture)
    transactions <- ExceptT (Right <$> Fixture.submitted fixture)
    except (unless (length transactions == expected) (Left (InvalidBuildingRequest "Unexpected workflow stage count")))
  _ <- must result
  pure ()

payment :: IO ()
payment = execute 1 (\context _ -> Workflow.runPayment context (Workflow.wallet context) 2000000)

nativeMint :: IO ()
nativeMint = execute 2 $ \context fixture ->
  Workflow.runMintBurn context (Script.Native (Native.signature (Fixture.paymentHash fixture))) Nothing AssetName.empty 3

plutusMint :: IO ()
plutusMint = execute 3 $ \context _ -> runExceptT $ do
  script <- ExceptT Scripts.alwaysSucceedsV3
  output <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 30000000) Datum.NoDatum (Just (Script.Plutus script)))
  funded <- ExceptT (Workflow.runStage context (Plan.payTo output))
  identifier <- ExceptT (Tx.transactionId funded)
  references <- ExceptT (Provider.resolveInputs (Workflow.provider context) [Input.input identifier 0])
  reference <- except $ case references of
    [value] -> Right value
    _ -> Left (InvalidBuildingRequest "Reference script did not resolve exactly once")
  ExceptT (Workflow.runMintBurn context (Script.Plutus script) (Just reference) AssetName.empty 3)

nativeSpend :: IO ()
nativeSpend = execute 2 $ \context fixture ->
  Workflow.runLockSpend context (Script.Native (Native.signature (Fixture.paymentHash fixture))) 4000000

plutusSpend :: IO ()
plutusSpend = execute 2 $ \context _ -> do
  script <- Scripts.alwaysSucceedsV3 >>= must
  Workflow.runLockSpend context (Script.Plutus script) 4000000

deferredSpends :: IO ()
deferredSpends = do
  execute 2 $ \context _ -> runExceptT $ do
    script <- Script.Plutus <$> ExceptT Scripts.selfIndex
    transactions <- ExceptT (Workflow.runDeferredSelf context script)
    except (checkDeferredTransactions script [1000000] transactions)
  execute 3 $ \context _ -> runExceptT $ do
    script <- Script.Plutus <$> ExceptT Scripts.orderPairing
    transactions <- ExceptT (Workflow.runDeferredBatch context script)
    except (checkDeferredTransactions script [1200000, 1500000] transactions)

checkDeferredTransactions :: Script.Script -> [Integer] -> [Tx.Transaction] -> Either Error ()
checkDeferredTransactions script payouts transactions = case reverse transactions of
  settled : funding -> do
    let fields = Body.bodyFields . Body.toBody . Tx.body
        outputs = Fields.fieldOutputs . fields
        fundedAmounts = map (map Output.value . take 1 . outputs) funding
        paidAmounts = map Output.value (take (length payouts) (outputs settled))
        noReferences = all (maybe True null . Fields.fieldReferenceInputs . fields) transactions
        noDeployments = all (all ((== Nothing) . Output.referenceScript) . outputs) transactions
        inlineWitness = script `elem` Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses settled))
    unless (length funding == length payouts && all (== [Value.lovelace 2000000]) fundedAmounts) (Left (InvalidBuildingRequest "Deferred funding must match the source's two-ADA orders"))
    unless (paidAmounts == map Value.lovelace payouts) (Left (InvalidBuildingRequest "Deferred explicit payouts differ from the source"))
    unless (noReferences && noDeployments && inlineWitness) (Left (InvalidBuildingRequest "Deferred settlement must attach its script inline without reference deployments"))
  [] -> Left (InvalidBuildingRequest "Missing deferred workflow transactions")

invalidIndex :: IO ()
invalidIndex = execute 1 $ \context fixture -> runExceptT $ do
  script <- ExceptT Scripts.selfIndex
  digest <- ExceptT (Script.hash (Script.Plutus script))
  let address = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.ScriptCredential digest))
  output <- except (Output.mkOutput address (Value.lovelace 4000000) (Datum.InlineDatum Workflow.voidArgument) Nothing)
  _ <- ExceptT (Workflow.runStage context (Plan.payTo output))
  values <- ExceptT (Right <$> Fixture.currentUtxos fixture)
  locked <- except (maybe (Left (InvalidBuildingRequest "Missing funded script")) Right (find ((== address) . Output.address . Utxo.output) values))
  let wrong = Data.fromData (Data.Constr 0 [Data.Integer 999])
  result <- ExceptT (Right <$> Workflow.runStage context (Plan.spendWith locked (Just wrong) Nothing <> Plan.attachScript (Script.Plutus script)))
  except (unless (isLeft result) (Left (InvalidBuildingRequest "Actual self-index validator accepted an invalid argument")))

pool :: IO (Credential.KeyHash Credential.StakePool)
pool = must (Credential.keyHashFromBytes (B.replicate 28 10))

metadata :: IO Anchor.Anchor
metadata = do
  url <- must (Anchor.mkUrl "https://example.com/native-workflow")
  digest <- must (Anchor.dataHashFromBytes (B.replicate 32 0))
  pure (Anchor.Anchor url digest)

keyRewards :: IO ()
keyRewards = execute 2 $ \context fixture -> do
  operator <- pool
  Workflow.runRewardCycle context (Fixture.stakeCredential fixture) Nothing operator 2000000

scriptRewards :: IO ()
scriptRewards = execute 2 $ \context _ -> do
  script <- Scripts.alwaysSucceedsV2 >>= must
  digest <- Script.hash (Script.Plutus script) >>= must
  operator <- pool
  Workflow.runRewardCycle context (Credential.ScriptCredential digest) (Just (Script.Plutus script)) operator 2000000

withdrawZero :: IO ()
withdrawZero = execute 2 $ \context _ -> do
  script <- Scripts.withdrawZero >>= must
  digest <- Script.hash (Script.Plutus script) >>= must
  operator <- pool
  Workflow.runWithdrawZero context (Credential.ScriptCredential digest) (Script.Plutus script) operator 2000000

dreps :: IO ()
dreps = do
  execute 4 $ \context fixture -> do
    anchor <- metadata
    Workflow.runDRepCycle context (Fixture.drepCredential fixture) Nothing 2000000 (Fixture.stakeCredential fixture) 2000000 anchor
  execute 4 $ \context fixture -> do
    script <- Scripts.alwaysSucceedsV3 >>= must
    digest <- Script.hash (Script.Plutus script) >>= must
    anchor <- metadata
    Workflow.runDRepCycle context (Credential.ScriptCredential digest) (Just (Script.Plutus script)) 2000000 (Fixture.stakeCredential fixture) 2000000 anchor

votes :: IO ()
votes = do
  previous <- must (Id.fromBytes (B.replicate 32 11))
  anchor <- metadata
  let action = ActionId.ActionId previous 0
  execute 3 $ \context fixture -> Workflow.runVoteCycle context (Fixture.drepCredential fixture) Nothing 2000000 anchor action
  execute 3 $ \context _ -> do
    script <- Scripts.alwaysSucceedsV3 >>= must
    digest <- Script.hash (Script.Plutus script) >>= must
    Workflow.runVoteCycle context (Credential.ScriptCredential digest) (Just (Script.Plutus script)) 2000000 anchor action

treasury :: IO ()
treasury = execute 2 $ \context fixture -> runExceptT $ do
  script <- ExceptT Scripts.alwaysSucceedsV3
  anchor <- ExceptT (Right <$> metadata)
  let account = Reward.fromCredential Network.testnet (Fixture.stakeCredential fixture)
  _ <- ExceptT (Workflow.runTreasuryWithdrawal context account 1000 (Script.Plutus script) anchor)
  ExceptT (Workflow.runDonation context 100000)

batch :: IO ()
batch = execute 2 $ \context fixture -> runExceptT $ do
  -- Keep separate ordinary wallet funding for the outer batcher, as the native
  -- example does; the independently signed intent spends only output zero.
  funding <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 50000000) Datum.NoDatum Nothing)
  prepared <- ExceptT (Workflow.runStage context (Plan.payTo funding))
  identifier <- ExceptT (Tx.transactionId prepared)
  inputs <- ExceptT (Provider.resolveInputs (Workflow.provider context) [Input.input identifier 0])
  input <- except $ case inputs of
    [value] -> Right value
    _ -> Left (InvalidBuildingRequest "Prepared local input did not resolve exactly once")
  params <- ExceptT (Provider.protocolParameters (Workflow.provider context))
  output <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 10000000) Datum.NoDatum Nothing)
  let intent = SubPlan.spend input <> SubPlan.payTo output
  local <- ExceptT (SubBuilder.build (SubBuilder.Config params (Workflow.slots context) Fields.Testnet) intent)
  signed <- ExceptT (Fixture.signIntent fixture local)
  transaction <- ExceptT (Workflow.runSignedBatch context [(signed, SubPlan.resolvedInputs intent)] mempty)
  let actual = fmap (map Sub.encodeCbor) (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
  except (unless (actual == Just [Sub.encodeCbor signed]) (Left (InvalidBuildingRequest "Signed intent bytes changed")))
  pure transaction

confirmation :: IO ()
confirmation = do
  result <- Fixture.withFixture $ \context fixture -> runExceptT $ do
    let backend = (Workflow.provider context) {Provider.awaitTransaction = \_ _ -> pure (Right False)}
        changed = context {Workflow.provider = backend}
    attempt <- ExceptT (Right <$> Workflow.runMintBurn changed (Script.Native (Native.signature (Fixture.paymentHash fixture))) Nothing AssetName.empty 1)
    except (unless (isLeft attempt) (Left (InvalidBuildingRequest "Timeout did not abort flow")))
    transactions <- ExceptT (Right <$> Fixture.submitted fixture)
    except (unless (length transactions == 1) (Left (InvalidBuildingRequest "Dependent burn ran after timeout")))
  _ <- must result
  pure ()

guardedBatch :: IO ()
guardedBatch = execute 2 $ \context fixture -> do
  validator <- Scripts.v4Validator >>= must
  guard <- Scripts.v4Guard >>= must
  Workflow.runGuardedSub context (Script.Plutus validator) (Script.Plutus guard) (Fixture.signIntent fixture)

swap :: IO ()
swap = do
  result <- Swap.runSwap >>= must
  Fixture.verifyTransaction (Swap.transaction result) >>= must
  let subs = Body.bodySubTransactions (Body.toBody (Tx.body (Swap.transaction result)))
  fmap (map Sub.encodeCbor) subs @?= Just [Sub.encodeCbor (Swap.buyerIntent result), Sub.encodeCbor (Swap.sellerIntent result)]

invalidSignature :: IO ()
invalidSignature = do
  result <- Fixture.withFixture $ \context fixture -> runExceptT $ do
    before <- ExceptT (Right <$> Fixture.currentUtxos fixture)
    zero <- except (Signature.fromBytes (B.replicate 64 0))
    let wrongSigner = Signer.Signer $ \transaction -> runExceptT $ do
          original <- ExceptT (Signer.signTransaction (Workflow.signer context) transaction)
          let badWitnesses = [Witness.verificationWitness (Witness.publicKey witness) zero | witness <- Witnesses.verificationWitnesses (Witnesses.toWitnesses original)]
          Witnesses.fromWitnesses <$> except (Witnesses.mkWitnesses badWitnesses [] [] [] [])
        tamperedContext = context {Workflow.signer = wrongSigner}
    attempt <- ExceptT (Right <$> Workflow.runPayment tamperedContext (Workflow.wallet context) 2000000)
    except (unless (attempt == Left (InvalidBuildingRequest "Fixture verification witness does not verify against its transaction body")) (Left (InvalidBuildingRequest "Invalid fixture signature was accepted")))
    after <- ExceptT (Right <$> Fixture.currentUtxos fixture)
    history <- ExceptT (Right <$> Fixture.submitted fixture)
    except (unless (before == after && null history) (Left (InvalidBuildingRequest "Rejected signature changed fixture state")))
  _ <- must result
  pure ()

-- The address index may temporarily expose both newly created and already spent
-- outputs, or no outputs. Neither observation is a usable next-stage snapshot.
indexLag :: IO ()
indexLag = do
  result <- Fixture.withFixture $ \context fixture -> runExceptT $ do
    before <- liftIO (Fixture.currentUtxos fixture)
    queries <- liftIO (newIORef (0 :: Int))
    pauses <- liftIO (newIORef (0 :: Int))
    let original = Workflow.provider context
        backend =
          original
            { Provider.utxosAt = \address -> do
                number <- atomicModifyIORef' queries (\count -> (count + 1, count))
                current <- Provider.utxosAt original address
                pure $ case number of
                  1 -> fmap (before <>) current
                  2 -> Right []
                  _ -> current
            }
        changed = context {Workflow.provider = backend}
    output <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 2000000) Datum.NoDatum Nothing)
    _ <- ExceptT (Workflow.runStageWithIndexPolling (pure 0) (modifyIORef' pauses (+ 1)) changed (Plan.payTo output))
    pauseCount <- liftIO (readIORef pauses)
    queryCount <- liftIO (readIORef queries)
    transactions <- liftIO (Fixture.submitted fixture)
    except (unless (pauseCount == 2 && queryCount == 4 && length transactions == 1) (Left (InvalidBuildingRequest "Index lag did not wait for both created and consumed output visibility")))
  _ <- must result
  pure ()

indexTimeout :: IO ()
indexTimeout = do
  result <- Fixture.withFixture $ \context fixture -> runExceptT $ do
    before <- liftIO (Fixture.currentUtxos fixture)
    ticks <- liftIO (newIORef [0, 1000000])
    pauses <- liftIO (newIORef (0 :: Int))
    let original = Workflow.provider context
        backend = original {Provider.utxosAt = \_ -> pure (Right before)}
        changed = context {Workflow.provider = backend, Workflow.confirmationTimeoutMillis = 1}
        clock = atomicModifyIORef' ticks $ \case
          value : rest -> (rest, value)
          [] -> ([], 1000000)
    output <- except (Output.mkOutput (Workflow.wallet context) (Value.lovelace 2000000) Datum.NoDatum Nothing)
    attempt <- liftIO (Workflow.runStageWithIndexPolling clock (modifyIORef' pauses (+ 1)) changed (Plan.payTo output))
    transactions <- liftIO (Fixture.submitted fixture)
    pauseCount <- liftIO (readIORef pauses)
    except (unless (attempt == Left (InvalidBuildingRequest "Confirmed transaction is not yet reflected in the wallet index; dependent stages stopped") && length transactions == 1 && pauseCount == 0) (Left (InvalidBuildingRequest "Index timeout did not stop exactly once at its monotonic deadline")))
  _ <- must result
  pure ()
