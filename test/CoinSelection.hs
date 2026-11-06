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

-- | Native contract sources: cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1
-- coin_selector.c, large_first_coin_selector.c, utxo_list.c and fee.c;
-- Apache-2.0. Cases use fresh typed public values and actual native dispatch.
module CoinSelection (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.CoinSelection as Selection
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.CoinSelection as Wire
import qualified Cometa.Internal.CoinSelection.Native as Native
import qualified Cometa.Internal.FFI.CoinSelection as FFI
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, finally, throwIO, try)
import Control.Monad (forM_, replicateM_)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Fixtures.ProtocolParameters as Fixture
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
    "Coin selection"
    [ testCase "direct checked selection and actual native callback agree" checkDispatch,
      testCase "preselected may be outside or identically overlap available" checkOverlap,
      testCase "request reference conflicts and target/parameter boundaries fail early" checkRequests,
      testCase "full selection accounting rejects dropped mandatory and changed snapshots" checkLaws,
      testCase "change minimum Ada uses actual native output sizing" checkMinimum,
      testCase "exact expected callback errors recover on the same runtime" checkErrors,
      testCase "exceptions and lazy callback results unwind all native owners" checkExceptions,
      testCase "malformed three-output replies release each partial output" checkPartial,
      testCase "retained runtime alias and repeated callbacks survive GC" checkRetained,
      testCase "reentrant selection fails fast with shared busy error" checkReentry,
      testCase "cancellation joins callback finalizer and releases registrations" checkCancellation,
      testProperty "generated full selections satisfy native dispatch and balance laws" propSelection
    ]

must :: (Show e) => Either e a -> IO a
must value = case value of
  Left failure -> assertFailure (show failure) >> fail "Invalid fixture"
  Right result -> pure result

fixture :: IO (Selection.SelectionRequest, Selection.Selection)
fixture = do
  params <- must Fixture.parameters
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  txId <- must (Id.fromBytes (B.replicate 32 8))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
      resolved ix amount = do
        out <- Output.mkOutput destination (Value.lovelace amount) Datum.NoDatum Nothing
        pure (Utxo.utxo (Input.input txId ix) out)
  mandatory <- must (resolved 0 3000000)
  candidate <- must (resolved 1 7000000)
  spare <- must (resolved 2 2000000)
  hint <- must (Output.mkOutput destination (Value.lovelace 1000000) Datum.NoDatum Nothing)
  change <- must (Output.mkOutput destination (Value.lovelace 4000000) Datum.NoDatum Nothing)
  request <- must (Selection.mkSelectionRequest (Selection.SelectionOptions [mandatory] [candidate, spare] (Value.lovelace 6000000) (Just [hint]) destination params))
  pure (request, Selection.Selection [mandatory, candidate] [spare] [change])

options :: Selection.SelectionRequest -> Selection.SelectionOptions
options request = Selection.SelectionOptions (Selection.preselected request) (Selection.available request) (Selection.target request) (Selection.outputHints request) (Selection.changeAddress request) (Selection.parameters request)

fixed :: Selection.Selection -> Selection.Selector
fixed result = Selection.Selector (\_ -> pure (Right result))

checkDispatch :: IO ()
checkDispatch = do
  (request, result) <- fixture
  let selector = Selection.Selector $ \observed -> do
        observed @?= request
        pure (Right result)
  Selection.select selector request >>= (@?= Right result)
  Native.invoke selector request >>= (@?= Right result)
  Wire.decodeRequest (Wire.encodeRequest request) @?= Right request
  Wire.decodeSelection (Wire.encodeSelection result) @?= Right result

checkOverlap :: IO ()
checkOverlap = do
  (request, result) <- fixture
  let raw = options request
  overlap <- must (Selection.mkSelectionRequest (raw {Selection.selectionAvailable = Selection.preselected request ++ Selection.available request}))
  Native.invoke (fixed result) overlap >>= (@?= Right result)
  Selection.validateSelection request result @?= Right ()
  Selection.validateSelection overlap result @?= Right ()

checkRequests :: IO ()
checkRequests = do
  (request, _) <- fixture
  let raw = options request
      mandatory = Selection.preselected request
      candidates = Selection.available request
      invalid = [raw {Selection.selectionPreselected = mandatory ++ mandatory}, raw {Selection.selectionAvailable = candidates ++ candidates}, raw {Selection.selectionTarget = Value.lovelace (negate (2 ^ (63 :: Int)) - 1)}, raw {Selection.selectionTarget = Value.lovelace (2 ^ (63 :: Int))}, raw {Selection.selectionParameters = (Selection.parameters request) {Parameters.parameterAdaPerUtxoByte = Nothing}}]
  forM_ invalid $ \value -> assertBool "invalid request accepted" (isLeft (Selection.mkSelectionRequest value))
  case mandatory of
    [original] -> do
      out <- must (Output.mkOutput (Selection.changeAddress request) (Value.lovelace 1) Datum.NoDatum Nothing)
      let conflicting = Utxo.utxo (Utxo.input original) out
      assertBool "conflicting overlap" (isLeft (Selection.mkSelectionRequest (raw {Selection.selectionAvailable = conflicting : candidates})))
    _ -> assertFailure "Unexpected mandatory fixture"

checkLaws :: IO ()
checkLaws = do
  (request, result) <- fixture
  let chosen = Selection.selected result
      invalid = [result {Selection.selected = chosen ++ chosen}, result {Selection.selected = drop 1 chosen}, result {Selection.remaining = []}, result {Selection.change = []}]
  forM_ invalid $ \value -> do
    assertBool "invalid pure law accepted" (isLeft (Selection.validateSelection request value))
    answer <- Native.invoke (fixed value) request
    assertBool "invalid callback result accepted" (isLeft answer)
  case chosen of
    first : rest -> do
      out <- must (Output.mkOutput (Selection.changeAddress request) (Value.lovelace 3000001) Datum.NoDatum Nothing)
      let changed = Utxo.utxo (Utxo.input first) out
      assertBool "changed input snapshot" (isLeft (Selection.validateSelection request (result {Selection.selected = changed : rest})))
    _ -> assertFailure "Missing selected fixture"

checkMinimum :: IO ()
checkMinimum = do
  (request, result) <- fixture
  tiny <- must (Output.mkOutput (Selection.changeAddress request) (Value.lovelace 1) Datum.NoDatum Nothing)
  tinyRequest <- must (Selection.mkSelectionRequest ((options request) {Selection.selectionTarget = Value.lovelace 9999999}))
  let tinyResult = result {Selection.change = [tiny]}
  Selection.validateSelection tinyRequest tinyResult @?= Right ()
  Selection.select (fixed tinyResult) tinyRequest >>= \answer -> assertBool "underfunded change accepted" (isLeft answer)
  Native.invoke (fixed tinyResult) tinyRequest >>= \answer -> assertBool "native callback underfunded change accepted" (isLeft answer)
  zeroCost <- must (Selection.mkSelectionRequest ((options tinyRequest) {Selection.selectionParameters = (Selection.parameters request) {Parameters.parameterAdaPerUtxoByte = Just 0}}))
  Selection.select (fixed tinyResult) zeroCost >>= (@?= Right tinyResult)

checkErrors :: IO ()
checkErrors = do
  (request, result) <- fixture
  first <- newIORef True
  let failure = InvalidSelection "deterministic selector failure"
      selector = Selection.Selector $ \_ -> do
        failNow <- readIORef first
        writeIORef first False
        pure (if failNow then Left failure else Right result)
  answer <- Native.withSelector selector $ \runtime -> do
    Native.invokeWith runtime request >>= (@?= Left failure)
    Native.invokeWith runtime request
  answer @?= Right result

checkExceptions :: IO ()
checkExceptions = do
  (request, _) <- fixture
  baseline <- Runtime.liveContexts
  let thrown = Selection.Selector (\_ -> throwIO (userError "selector exploded"))
      lazy = Selection.Selector (\_ -> pure (Right (Selection.Selection [error "lazy selector output"] [] [])))
  forM_ [(thrown, "selector exploded"), (lazy, "lazy selector output")] $ \(selector, message) -> do
    result <- try (Native.invoke selector request) :: IO (Either SomeException (Either Error Selection.Selection))
    case result of
      Left failure -> assertBool "exception message lost" (message `isInfixOf` displayException failure)
      Right _ -> assertFailure "Callback exception did not propagate"
  Runtime.liveContexts >>= (@?= baseline)

checkPartial :: IO ()
checkPartial = do
  (request, _) <- fixture
  baseline <- Runtime.liveContexts
  -- First list allocated before second fails; both lists allocated before third
  -- fails; then a complete result with extra trailing bytes. Each must unwind.
  forM_ [B.pack [0x83, 0x80, 0xf6, 0x80], B.pack [0x83, 0x80, 0x80, 0xf6], B.pack [0x83, 0x80, 0x80, 0x80, 0]] $ \reply -> do
    answer <- Runtime.withRuntime (\_ _ -> pure (Right reply)) $ \runtime -> Runtime.withOperation runtime $ \context ->
      Runtime.withBytes (Wire.encodeRequest request) $ \bytes size -> Runtime.withOwnedBuffer "test.selector.partial" (FFI.cSelect context bytes size)
    assertBool "malformed reply accepted" (isLeft answer)
  Runtime.liveContexts >>= (@?= baseline)

checkRetained :: IO ()
checkRetained = do
  (request, result) <- fixture
  baseline <- Runtime.liveContexts
  answer <- Native.withSelector (fixed result) $ \original -> Runtime.withRetained original $ \alias -> do
    Runtime.close original >>= must
    replicateM_ 32 $ do
      performGC
      Native.invokeWith alias request >>= (@?= Right result)
    pure (Right result)
  answer @?= Right result
  Runtime.liveContexts >>= (@?= baseline)

checkReentry :: IO ()
checkReentry = do
  (request, result) <- fixture
  slot <- newEmptyMVar
  let selector = Selection.Selector $ \_ -> do
        runtime <- takeMVar slot
        putMVar slot runtime
        Native.invokeWith runtime request >>= (@?= Left RuntimeBusy)
        pure (Right result)
  answer <- Native.withSelector selector $ \runtime -> putMVar slot runtime >> Native.invokeWith runtime request
  answer @?= Right result

checkCancellation :: IO ()
checkCancellation = do
  (request, _) <- fixture
  baseline <- Runtime.liveContexts
  entered <- newEmptyMVar
  blocker <- newEmptyMVar
  finalized <- newEmptyMVar
  finished <- newEmptyMVar
  let selector = Selection.Selector $ \_ -> (putMVar entered () >> takeMVar blocker) `finally` putMVar finalized ()
  worker <- forkFinally (Native.invoke selector request) (putMVar finished)
  takeMVar entered
  killThread worker
  joined <- timeout 5000000 (takeMVar finished)
  case joined of
    Just (Left _) -> pure ()
    _ -> assertFailure "Cancellation did not join native selector unwind"
  timeout 5000000 (takeMVar finalized) >>= (@?= Just ())
  Runtime.liveContexts >>= (@?= baseline)

propSelection :: Property
propSelection = property $ do
  amount <- forAll (Gen.integral (Range.linear 1 100000000))
  (request, result) <- evalIO fixture
  case Selection.selected result of
    first : _ -> do
      output <- evalEither (Output.mkOutput (Selection.changeAddress request) (Value.lovelace amount) Datum.NoDatum Nothing)
      let utxo = Utxo.utxo (Utxo.input first) output
      exact <- evalEither (Selection.mkSelectionRequest ((options request) {Selection.selectionPreselected = [], Selection.selectionAvailable = [utxo], Selection.selectionTarget = Value.lovelace amount, Selection.selectionOutputHints = Nothing}))
      let answer = Selection.Selection [utxo] [] []
      selected <- evalIO (Native.invoke (fixed answer) exact) >>= evalEither
      selected === answer
      Selection.validateSelection exact selected === Right ()
    _ -> pure ()
