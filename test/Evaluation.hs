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
{-# LANGUAGE ScopedTypeVariables #-}

-- | Injected evaluation and signing workflows, correspondence and callback lifetime.
module Evaluation (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Evaluation as Values
import qualified Cometa.Internal.EvaluationNative as Native
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.KeyHandler.Software as Software
import qualified Cometa.PlutusData as Data
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Signer as Signer
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, displayException, finally, fromException, try)
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text as Text
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Evaluation and signer injection"
    [ testCase "direct and native budgets correspond exactly without installing edits" correspondence,
      testCase "explicit sub-target returns only that level's arguments and budgets" subTarget,
      testCase "duplicate, missing, unknown identifiers and changed arguments fail" invalidResults,
      testCase "invalid target and duplicate resolved refs fail before dispatch" invalidRequests,
      testCase "native repeated callbacks and retained aliases root registrations" retention,
      testCase "native callback domain errors and thrown/lazy exceptions preserve identity" exceptions,
      testCase "same-registration callback reentry fails promptly" reentry,
      testCase "cancellation joins callback cleanup and evaluator remains usable" cancellation,
      testCase "partial native parse failures and malformed replies release resources" partialFailures,
      testCase "signer closures compose existing scoped keys and handlers" signing,
      testProperty "generated full-range budgets retain exact redeemer arguments" propBudgets
    ]

fixture :: Either Error Tx.Transaction
fixture = do
  argument <- Data.decodeCbor (B.pack [0x18, 0])
  let redeemers = [Redeemer.Redeemer purpose (fromIntegral (fromEnum purpose)) argument (ExUnits 1 2) | purpose <- [minBound .. maxBound]]
  ws <- Witnesses.mkWitnesses [] [] [] [] redeemers
  subWs <- Witnesses.mkWitnesses [] [] [] [] [Redeemer.Redeemer Redeemer.Minting maxBound argument (ExUnits 3 4)]
  subBody <- SubBody.fromBody (SubBody.body [] [])
  body <- Body.fromBody (Body.body [] [] 0) {Body.bodySubTransactions = Just [Sub.assemble subBody (Witnesses.fromWitnesses subWs) Nothing]}
  pure (Tx.assemble body (Witnesses.fromWitnesses ws) Nothing)

computed :: Evaluation.Target -> Tx.Transaction -> Either Error Evaluation.Budgets
computed target transaction = do
  values <- Values.targetRedeemers target transaction
  Evaluation.mkBudgets [(Evaluation.RedeemerId (Redeemer.purpose r) (Redeemer.index r), ExUnits maxBound (fromIntegral (Redeemer.index r))) | r <- values]

backend :: Evaluation.Evaluator
backend = Evaluation.Evaluator (\target transaction _ -> pure (computed target transaction))

correspondence :: IO ()
correspondence = do
  transaction <- require fixture
  let original = Tx.encodeCbor transaction
  expected <- require (computed Evaluation.TopLevel transaction)
  Evaluation.evaluate backend Evaluation.TopLevel transaction [] >>= (@?= Right expected)
  actual <- Native.withEvaluator backend Evaluation.TopLevel $ \native -> Native.evaluate native transaction []
  actual @?= Right expected
  providerResult <- Native.withProviderEvaluator backend $ \native -> Native.evaluateRepeated 3 native transaction []
  providerResult @?= Right expected
  Tx.encodeCbor transaction @?= original
  resolved <- require (hexBytes utxoHex >>= Utxo.decodeCbor)
  observed <- newIORef Nothing
  let snapshotEvaluator = Evaluation.Evaluator (\target tx inputs -> writeIORef observed (Just (tx, inputs)) >> pure (computed target tx))
      indefiniteBytes = B.singleton 0x9f <> B.drop 1 original <> B.singleton 0xff
  indefinite <- require (Tx.decodeCbor indefiniteBytes)
  snapshotResult <- Native.withEvaluator snapshotEvaluator Evaluation.TopLevel $ \native -> Native.evaluate native indefinite [resolved]
  snapshotResult @?= Right expected
  snapshot <- readIORef observed
  case snapshot of
    Nothing -> assertFailure "native evaluator did not receive resolved context"
    Just (received, inputs) -> do
      -- Snapshots remain valid after C owners and the callback registration die.
      Body.toCbor (Tx.body received) @?= Body.toCbor (Tx.body indefinite)
      Witnesses.toCbor (Tx.witnesses received) @?= Witnesses.toCbor (Tx.witnesses indefinite)
      inputs @?= [resolved]
  Tx.encodeCbor indefinite @?= indefiniteBytes
  -- No implicit budget installation: the original budgets still equal [1,2].
  let originalRedeemers = Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses transaction))
  map Redeemer.executionUnits originalRedeemers @?= replicate 7 (ExUnits 1 2)
  emptyBody <- require (Body.fromBody (Body.body [] [] 0))
  empty <- require (Evaluation.mkBudgets [])
  Evaluation.evaluate backend Evaluation.TopLevel (Tx.fromBody emptyBody) [] >>= (@?= Right empty)

subTarget :: IO ()
subTarget = do
  transaction <- require fixture
  let target = Evaluation.SubTransaction 0
  expected <- require (computed target transaction)
  result <- Native.withEvaluator backend target $ \native -> Native.evaluate native transaction []
  result @?= Right expected
  map fst (Evaluation.budgets expected) @?= [Evaluation.RedeemerId Redeemer.Minting maxBound]
  Evaluation.evaluate backend (Evaluation.SubTransaction maxBound) transaction [] >>= assertBool "out of range target" . isLeft

invalidResults :: IO ()
invalidResults = do
  transaction <- require fixture
  let identifier = Evaluation.RedeemerId Redeemer.Spending 0
      budget = (identifier, ExUnits 1 2)
  assertBool "duplicate rejected" (isLeft (Evaluation.mkBudgets [budget, budget]))
  missing <- require (Evaluation.mkBudgets [])
  extra <- require (Evaluation.mkBudgets [(Evaluation.RedeemerId Redeemer.Guarding maxBound, ExUnits 1 2)])
  forM_ [missing, extra] $ \result -> do
    let evaluator = Evaluation.Evaluator (\_ _ _ -> pure (Right result))
    Evaluation.evaluate evaluator Evaluation.TopLevel transaction [] >>= assertBool "incomplete result rejected" . isLeft
    Native.withEvaluator evaluator Evaluation.TopLevel (\native -> Native.evaluate native transaction []) >>= assertBool "native incomplete result rejected" . isLeft
  computedBudgets <- require (computed Evaluation.TopLevel transaction)
  values <- require (Values.checkedRedeemers Evaluation.TopLevel transaction computedBudgets)
  let changed = map (\r -> r {Redeemer.argument = Data.fromData (Data.Integer 0)}) values
  assertBool "semantic-equal argument with different exact bytes rejected" (isLeft (Values.budgetsFromRedeemers Evaluation.TopLevel transaction changed))

invalidRequests :: IO ()
invalidRequests = do
  transaction <- require fixture
  calls <- newIORef (0 :: Int)
  let evaluator = Evaluation.Evaluator (\target tx _ -> modifyIORef' calls (+ 1) >> pure (computed target tx))
  Evaluation.evaluate evaluator (Evaluation.SubTransaction 1) transaction [] >>= assertBool "invalid target rejected" . isLeft
  readIORef calls >>= (@?= 0)
  -- Duplicate resolution is checked even when output bytes agree. Use a typed
  -- fixture from an independently encoded UTxO, rather than faking a handle.
  resolved <- require (hexBytes utxoHex >>= Utxo.decodeCbor)
  Evaluation.evaluate evaluator Evaluation.TopLevel transaction [resolved, resolved] >>= assertBool "duplicate refs rejected" . isLeft
  readIORef calls >>= (@?= 0)

retention :: IO ()
retention = do
  baseline <- Runtime.liveContexts
  transaction <- require fixture
  calls <- newIORef (0 :: Int)
  let evaluator =
        Evaluation.Evaluator
          ( \target tx _ -> do
              performGC
              modifyIORef' calls (+ 1)
              pure (computed target tx)
          )
  result <- Native.withEvaluator evaluator Evaluation.TopLevel $ \native -> Native.withRetained native $ \alias -> do
    Native.close native >>= (@?= Right ())
    Native.evaluate native transaction [] >>= (@?= Left RuntimeClosed)
    Native.evaluateRepeated 8 alias transaction []
  expected <- require (computed Evaluation.TopLevel transaction)
  result @?= Right expected
  readIORef calls >>= (@?= 8)
  Runtime.liveContexts >>= (@?= baseline)

exceptions :: IO ()
exceptions = do
  baseline <- Runtime.liveContexts
  transaction <- require fixture
  let expectedError = UnsupportedOperation (Text.replicate 2048 "e")
      failed = Evaluation.Evaluator (\_ _ _ -> pure (Left expectedError))
  result <- Native.withEvaluator failed Evaluation.TopLevel (\native -> Native.evaluate native transaction [])
  result @?= Left expectedError
  forM_ [Evaluation.Evaluator (\_ _ _ -> ioError (userError "evaluator throw")), Evaluation.Evaluator (\_ _ _ -> pure (Right (error "evaluator lazy poison")))] $ \evaluator -> do
    outcome <- try (Native.withEvaluator evaluator Evaluation.TopLevel (\native -> Native.evaluate native transaction []))
    case outcome of
      Left (cause :: SomeException) -> assertBool "exception preserved" ("evaluator" `Text.isInfixOf` Text.pack (displayException cause))
      Right _ -> assertFailure "callback exception was swallowed"
  Runtime.liveContexts >>= (@?= baseline)

reentry :: IO ()
reentry = within $ do
  transaction <- require fixture
  installed <- newIORef Nothing
  observed <- newEmptyMVar
  let evaluator =
        Evaluation.Evaluator
          ( \target tx _ -> do
              active <- readIORef installed
              case active of
                Nothing -> assertFailure "missing native evaluator" >> pure (Left RuntimeClosed)
                Just native -> do
                  nested <- Native.evaluate native tx []
                  putMVar observed nested
                  pure (computed target tx)
          )
  _ <- Native.withEvaluator evaluator Evaluation.TopLevel $ \native -> do
    writeIORef installed (Just native)
    Native.evaluate native transaction []
  takeMVar observed >>= (@?= Left RuntimeBusy)

cancellation :: IO ()
cancellation = within $ do
  transaction <- require fixture
  entered <- newEmptyMVar
  cleaned <- newEmptyMVar
  blocked <- newEmptyMVar
  finished <- newEmptyMVar
  calls <- newIORef (0 :: Int)
  let evaluator =
        Evaluation.Evaluator
          ( \target tx _ -> do
              index <- readIORef calls
              modifyIORef' calls (+ 1)
              if index == 0
                then (putMVar entered () >> takeMVar blocked) `finally` putMVar cleaned ()
                else pure (computed target tx)
          )
  result <- Native.withEvaluator evaluator Evaluation.TopLevel $ \native -> do
    worker <- forkFinally (Native.evaluate native transaction []) (putMVar finished)
    takeMVar entered
    killThread worker
    outcome <- takeMVar finished
    takeMVar cleaned
    case outcome of
      Left cause -> (fromException cause :: Maybe AsyncException) @?= Just ThreadKilled
      Right _ -> assertFailure "cancelled evaluation returned normally"
    Native.evaluate native transaction []
  assertBool "evaluator usable after cancellation" (not (isLeft result))

partialFailures :: IO ()
partialFailures = do
  baseline <- Runtime.liveContexts
  transaction <- require fixture
  -- First valid map entry allocates data/units/redeemer, then the second entry
  -- fails; trailing reply also fails after a whole list has been acquired.
  forM_ [B.pack [0xa2, 0x82, 0, 0, 0x82, 0, 0x82, 0, 0, 0x82, 1, 0, 0x82, 0], B.pack [0xa0, 0]] $ \reply ->
    replicateM_ 20 $ do
      result <- Native.withDispatch Evaluation.TopLevel (\_ _ -> pure (Right reply)) $ \native -> Native.runUnchecked 1 native (Tx.encodeCbor transaction) (B.singleton 0x80)
      assertBool "malformed reply rejected" (isLeft result)
  Native.withEvaluator backend Evaluation.TopLevel (\native -> Native.runUnchecked 1 native (B.pack [0x84, 0xa0]) (B.singleton 0x80)) >>= assertBool "partial tx parse fails" . isLeft
  Native.withEvaluator backend Evaluation.TopLevel (\native -> Native.runUnchecked 1 native (Tx.encodeCbor transaction) (B.pack [0x81, 0x82, 0x80])) >>= assertBool "partial UTxO parse fails" . isLeft
  Runtime.liveContexts >>= (@?= baseline)

signing :: IO ()
signing = do
  transaction <- require fixture
  escaped <- newEmptyMVar
  partial <- Key.withNormalKey (B.replicate 32 4) $ \key -> do
    let signer = Signer.ed25519 key
    putMVar escaped signer
    Signer.signTransaction signer transaction
  witnesses <- require partial
  signed <- require (Tx.addWitnesses witnesses transaction)
  Body.toCbor (Tx.body signed) @?= Body.toCbor (Tx.body transaction)
  length (Witnesses.verificationWitnesses (Witnesses.toWitnesses witnesses)) @?= 1
  closedSigner <- takeMVar escaped
  Signer.signTransaction closedSigner transaction >>= (@?= Left SigningKeyClosed)
  normal <- Key.withNormalKey (B.replicate 32 4) $ \key -> Software.withSigningKey key "password" (pure "password") (\handler -> Signer.signTransaction (Signer.software handler) transaction)
  require normal >>= (@?= witnesses)
  let path = Path.derivationPath (Path.standardAccountPath minBound) Path.externalRole minBound
  hierarchical <- Software.withEntropy (B.replicate 16 0) "password" (pure "password") (\handler -> Signer.signTransaction (Signer.bip32 handler (path :| [])) transaction)
  result <- require hierarchical
  length (Witnesses.verificationWitnesses (Witnesses.toWitnesses result)) @?= 1

propBudgets :: Property
propBudgets = property $ do
  amount <- forAll (Gen.word64 Range.constantBounded)
  index <- forAll (Gen.word32 Range.constantBounded)
  purpose <- forAll Gen.enumBounded
  argument <- evalEither (Data.decodeCbor (B.pack [0x18, 0]))
  ws <- evalEither (Witnesses.mkWitnesses [] [] [] [] [Redeemer.Redeemer purpose index argument (ExUnits 0 0)])
  body <- evalEither (Body.fromBody (Body.body [] [] 0))
  let transaction = Tx.assemble body (Witnesses.fromWitnesses ws) Nothing
  result <- evalEither (Evaluation.mkBudgets [(Evaluation.RedeemerId purpose index, ExUnits amount amount)])
  let evaluator = Evaluation.Evaluator (\_ _ _ -> pure (Right result))
  actual <- evalIO (Native.withEvaluator evaluator Evaluation.TopLevel (\native -> Native.evaluate native transaction []))
  actual === Right result
  bytes <- evalEither (Redeemer.encodeCollectionCbor [Redeemer.Redeemer purpose index argument (ExUnits amount amount)])
  decoded <- evalEither (Redeemer.decodeCollectionCbor bytes)
  map (Data.toCbor . Redeemer.argument) decoded === [Data.toCbor argument]

within :: IO a -> IO a
within action = do
  result <- timeout 5000000 action
  case result of
    Nothing -> assertFailure "callback operation timed out" >> fail "unreachable"
    Just value -> pure value

hexBytes :: Text.Text -> Either Error ByteString
hexBytes = maybe (Left InvalidHex) Right . Hex.decodeHex

require :: Either Error a -> IO a
require = either (\failure -> assertFailure (show failure) >> fail "unreachable") pure

-- Original deterministic fixture: input32zero/index0 and a legacy enterprise
-- output (network0, key28zero, lovelace1). No live chain or funded wallet data.
utxoHex :: Text.Text
utxoHex = "8282582000000000000000000000000000000000000000000000000000000000000000000082581d600000000000000000000000000000000000000000000000000000000001"
