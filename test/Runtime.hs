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
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Shared callback ownership, retry, grouped cancellation and alias evidence.
module Runtime (tests) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Internal.FFI.Native (NativeCode)
import qualified Cometa.Internal.Runtime as Runtime
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.MVar (tryPutMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket_, displayException, fromException, try, uninterruptibleMask_)
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Foreign.C.Types (CUInt (..))
import Foreign.Ptr (Ptr, nullPtr)
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Shared callback runtime"
    [ testCase "native failure preserves exact Error; handled failure and retry can recover" retries,
      testCase "native last-owner aliases and closed handles retain correct registration lifetime" aliases,
      testCase "duplicate contexts activate once and partial group acquisition rolls back" groups,
      testCase "callback reentry and overlap fail promptly without losing independent gates" reentry,
      testCase "lazy success, lazy failure and callback exceptions rethrow after native unwind" exceptions,
      testCase "group cancellation reaches the second callback and joins its finalizer" cancellation,
      testCase "group cancellation fans out past a masked dependent callback" dependentCancellation
    ]

probe :: Runtime.Runtime -> CUInt -> IO (Either Error ByteString)
probe runtime mode = Runtime.withOperation runtime $ \context ->
  Runtime.withOwnedBuffer "test.runtime" (cProbe context nullPtr mode)

retries :: IO ()
retries = do
  let expected = InvalidTransactionOutputValue (-42)
      handler operation _ = pure (if operation == 0 then Left expected else Right "recovered")
  before <- Runtime.liveContexts
  result <- Runtime.withRuntime handler $ \runtime -> do
    probe runtime 0 >>= (@?= Left expected)
    probe runtime 1 >>= (@?= Right (B.singleton 0x80))
    probe runtime 2 >>= (@?= Right "recovered")
    probe runtime 0 >>= (@?= Left expected)
    pure (Right ())
  result @?= Right ()
  Runtime.liveContexts >>= (@?= before)

aliases :: IO ()
aliases = do
  baseline <- Runtime.liveContexts
  escaped <- newEmptyMVar
  result <- Runtime.withRuntime (\_ bytes -> performGC >> pure (Right bytes)) $ \original -> do
    Runtime.liveContexts >>= (@?= baseline + 1)
    Runtime.withRetained original $ \alias -> do
      Runtime.close original >>= (@?= Right ())
      probe original 0 >>= (@?= Left RuntimeClosed)
      putMVar escaped alias
      replicateM_ 10 (probe alias 0 >>= (@?= Right (B.singleton 0x80)))
      pure (Right ())
  result @?= Right ()
  alias <- takeMVar escaped
  probe alias 0 >>= (@?= Left RuntimeClosed)
  Runtime.close alias >>= (@?= Right ())
  Runtime.liveContexts >>= (@?= baseline)

groups :: IO ()
groups = do
  result <- Runtime.withRuntime (\_ bytes -> pure (Right bytes)) $ \first ->
    Runtime.withRuntime (\_ bytes -> pure (Right bytes)) $ \second -> do
      Runtime.close second >>= (@?= Right ())
      Runtime.withOperations [first, second] (\_ -> pure (Right ())) >>= (@?= Left RuntimeClosed)
      probe first 0 >>= (@?= Right (B.singleton 0x80))
      lazyGroup <- try (Runtime.withOperations [first, error "lazy group handle"] (\_ -> pure (Right ()))) :: IO (Either SomeException (Either Error ()))
      assertBool "lazy group argument did not throw" (isLeft lazyGroup)
      probe first 0 >>= (@?= Right (B.singleton 0x80))
      Runtime.withRetained first $ \alias -> do
        both <- Runtime.withOperations [first, alias] $ \case
          [one, two] -> Runtime.withOwnedBuffer "test.runtime.group" (cProbe one two 3)
          _ -> pure (Left (InvalidCallbackResult "Incorrect context count"))
        both @?= Right (B.singleton 0x80)
        pure (Right ())
  result @?= Right ()

reentry :: IO ()
reentry = do
  current <- newIORef Nothing
  reentered <- newIORef Nothing
  let handler _ bytes = do
        selected <- readIORef current
        case selected of
          Nothing -> pure (Left (InvalidCallbackResult "Missing test runtime"))
          Just runtime -> do
            nested <- probe runtime 0
            writeIORef reentered (Just nested)
            Runtime.close runtime >>= (@?= Left RuntimeBusy)
            pure (Right bytes)
  result <- Runtime.withRuntime handler $ \runtime -> do
    writeIORef current (Just runtime)
    probe runtime 0
  result @?= Right (B.singleton 0x80)
  readIORef reentered >>= (@?= Just (Left RuntimeBusy))

exceptions :: IO ()
exceptions = do
  baseline <- Runtime.liveContexts
  forM_ [\_ _ -> pure (Right (error "lazy reply")), \_ _ -> pure (Left (UnsupportedOperation (error "lazy error"))), \_ _ -> ioError (userError "callback failed")] $ \handler -> do
    outcome <- try (Runtime.withRuntime handler (`probe` 0)) :: IO (Either SomeException (Either Error ByteString))
    assertBool "callback exception escaped as expected Error" (isLeft outcome)
    case outcome of
      Left failure -> assertBool "unexpected exception" (any (`isInfixOf` displayException failure) ["lazy reply", "lazy error", "callback failed"])
      Right _ -> assertFailure "callback unexpectedly succeeded"
  Runtime.liveContexts >>= (@?= baseline)

cancellation :: IO ()
cancellation = do
  baseline <- Runtime.liveContexts
  started <- newEmptyMVar
  finalized <- newEmptyMVar
  hold <- newEmptyMVar
  count <- newIORef (0 :: Int)
  let secondHandler _ bytes = do
        calls <- readIORef count
        modifyIORef' count (+ 1)
        if calls == 0
          then bracket_ (putMVar started ()) (putMVar finalized ()) (takeMVar hold)
          else pure (Right bytes)
  result <- Runtime.withRuntime (\_ bytes -> pure (Right bytes)) $ \first ->
    Runtime.withRuntime secondHandler $ \second -> do
      finished <- newEmptyMVar
      worker <-
        forkFinally
          ( Runtime.withOperations [first, second] $ \case
              [one, two] -> Runtime.withOwnedBuffer "test.runtime.cancelGroup" (cProbe one two 3)
              _ -> pure (Left (InvalidCallbackResult "Incorrect context count"))
          )
          (putMVar finished)
      takeMVar started
      Runtime.withOperations [second, first] (\_ -> pure (Right ())) >>= (@?= Left RuntimeBusy)
      joined <- timeout 5000000 (killThread worker >> takeMVar finished)
      case joined of
        Just (Left exception) -> fromException exception @?= Just ThreadKilled
        _ -> assertFailure "group cancellation did not join"
      takeMVar finalized
      probe first 0 >>= (@?= Right (B.singleton 0x80))
      probe second 0 >>= (@?= Right (B.singleton 0x80))
      pure (Right ())
  result @?= Right ()
  Runtime.liveContexts >>= (@?= baseline)

-- A serial throwTo implementation deadlocks here: the first callback masks
-- cancellation until the second callback's finalizer has run. The C probe invokes
-- both callbacks concurrently and does not return until both native threads join.
dependentCancellation :: IO ()
dependentCancellation = do
  baseline <- Runtime.liveContexts
  firstReady <- newEmptyMVar
  secondReady <- newEmptyMVar
  secondFinalized <- newEmptyMVar
  hold <- newEmptyMVar
  let firstHandler _ bytes = do
        putMVar firstReady ()
        uninterruptibleMask_ (takeMVar secondFinalized)
        pure (Right bytes)
      secondHandler _ _ = do
        takeMVar firstReady
        bracket_ (putMVar secondReady ()) (putMVar secondFinalized ()) (takeMVar hold)
  result <- Runtime.withRuntime firstHandler $ \first ->
    Runtime.withRuntime secondHandler $ \second -> do
      finished <- newEmptyMVar
      worker <-
        forkFinally
          ( Runtime.withOperations [first, second] $ \case
              [one, two] -> Runtime.withOwnedBuffer "test.runtime.dependentCancellation" (cProbe one two 4)
              _ -> pure (Left (InvalidCallbackResult "Incorrect context count"))
          )
          (putMVar finished)
      takeMVar secondReady
      joined <- timeout 5000000 (killThread worker >> takeMVar finished)
      case joined of
        Just (Left exception) -> fromException exception @?= Just ThreadKilled
        _ -> do
          -- Unblock even a regressed serial cancellation path before failing,
          -- so the test never strands native threads or callback registrations.
          _ <- tryPutMVar secondFinalized ()
          _ <- takeMVar finished
          assertFailure "group cancellation did not fan out"
      pure (Right ())
  result @?= Right ()
  Runtime.liveContexts >>= (@?= baseline)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_runtime_probe"
  cProbe :: Ptr Runtime.Context -> Ptr Runtime.Context -> CUInt -> Ptr (Ptr Runtime.Buffer) -> IO NativeCode
