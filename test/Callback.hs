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

-- | Ownership evidence against the actual pinned cardano-c provider callback.
-- The suite is sequential because it checks process-wide native allocation and
-- unwind counters; independent providers are explicitly overlapped below.
module Callback (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.Callback as Bridge
import qualified Cometa.Internal.FFI.Provider as FFI
import qualified Cometa.Internal.Provider as Provider
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, MaskingState (MaskedInterruptible, Unmasked), SomeException, bracket, fromException, getMaskingState, mask_, throw, throwIO, toException, try, uninterruptibleMask_)
import Control.Monad (replicateM_)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, mkWeakIORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust, isNothing)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (castPtr)
import Foreign.StablePtr (freeStablePtr, newStablePtr)
import Foreign.Storable (peek)
import System.Mem (performGC)
import System.Mem.Weak (Weak, deRefWeak)
import System.Timeout (timeout)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- TYPES ----------------------------------------------------------------------

-- Distinct from expected native failures, so exception identity is observable.
data CallbackException = CallbackException deriving (Eq, Show)

instance Exception CallbackException

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests = testCase "native provider callback ownership, exceptions and cancellation" $ do
  baseline <- Provider.liveCallbackContexts
  checkRegistrationRelease
  checkCopiedArguments baseline
  checkRetainedHandle baseline
  checkFailureRecovery
  checkExceptionalResults
  checkPendingCancellation
  checkCancellation baseline
  checkDelayedCancellation baseline
  checkFastCancellationRaces
  checkCallerMasking
  checkConcurrencyAndClose baseline
  checkReentry
  checkRepeatedFailures
  performGC
  Provider.liveCallbackContexts >>= (@?= baseline)

checkCopiedArguments :: Int -> IO ()
checkCopiedArguments baseline = do
  copied <- newIORef ByteString.empty
  Provider.withProvider
    ( \hash milliseconds -> do
        writeIORef copied hash
        hash @?= transactionId
        performGC
        pure (Right (milliseconds == maxBound))
    )
    $ \provider -> do
      performGC
      Provider.confirmTransaction provider transactionId 0 >>= (@?= Right False)
      Provider.confirmTransaction provider transactionId maxBound >>= (@?= Right True)
      Provider.confirmTransaction provider ByteString.empty 0 >>= (@?= Left (Provider.InvalidTransactionIdLength 0))
      replicateM_ 50 $ Provider.confirmTransaction provider transactionId 1 >>= (@?= Right False)

  performGC
  readIORef copied >>= (@?= transactionId)
  Provider.liveCallbackContexts >>= (@?= baseline)

checkRetainedHandle :: Int -> IO ()
checkRetainedHandle baseline = do
  escaped <- Provider.withProvider (\_ _ -> pure (Right True)) $ \original -> do
    Provider.withRetainedProvider original $ \retained -> do
      closeTwice original
      performGC
      Provider.liveCallbackContexts >>= (@?= baseline + 1)
      Provider.confirmTransaction original transactionId 0 >>= (@?= Left Provider.ProviderClosed)
      Provider.confirmTransaction retained transactionId 0 >>= (@?= Right True)
    pure original
  Provider.confirmTransaction escaped transactionId 0 >>= (@?= Left Provider.ProviderClosed)
  Provider.liveCallbackContexts >>= (@?= baseline)

checkFailureRecovery :: IO ()
checkFailureRecovery = do
  count <- newIORef (0 :: Int)
  Provider.withProvider
    ( \_ _ -> do
        previous <- readIORef count
        writeIORef count (previous + 1)
        pure (if previous == 0 then Left "declined" else Right True)
    )
    $ \provider -> do
      Provider.confirmTransaction provider transactionId 0
        >>= (@?= Left (Provider.ProviderNativeFailure (Code.toNumber Code.GenericFailure) "declined"))
      Provider.confirmTransaction provider transactionId 0 >>= (@?= Right True)

checkExceptionalResults :: IO ()
checkExceptionalResults =
  mapM_
    checkThrown
    [ \_ _ -> throwIO CallbackException,
      \_ _ -> pure (Right (throw CallbackException)),
      \_ _ -> pure (Left (throw CallbackException)),
      \_ _ -> pure (throw CallbackException)
    ]

checkRepeatedFailures :: IO ()
checkRepeatedFailures =
  replicateM_ 50 $ do
    Provider.withProvider (\_ _ -> pure (Left "expected failure")) $ \provider -> do
      result <- Provider.confirmTransaction provider transactionId 0
      result @?= Left (Provider.ProviderNativeFailure (Code.toNumber Code.GenericFailure) "expected failure")
    checkThrown (\_ _ -> throwIO CallbackException)

-- Callback exceptions may reach Haskell only after the C call has unwound.
checkThrown :: Provider.ConfirmationHandler -> IO ()
checkThrown handler = do
  before <- Provider.completedNativeCalls
  Provider.withProvider handler $ \provider -> do
    result <- try (Provider.confirmTransaction provider transactionId 0)
    result @?= Left CallbackException
    -- This counter is incremented in C after the real provider call and hash
    -- destructor. An exception escaping through the ABI cannot satisfy it.
    Provider.completedNativeCalls >>= (@?= before + 1)

-- The marker is reachable only through the handler after this helper returns.
-- A leaked StablePtr keeps it alive even after the native context counter falls.
checkRegistrationRelease :: IO ()
checkRegistrationRelease = do
  finalized <- newEmptyMVar
  (closed, weak) <- withMarkedProvider (putMVar finalized ()) $ \provider marker -> do
    performGC
    deRefWeak marker >>= assertBool "native registration roots captured state" . isJust
    Provider.confirmTransaction provider transactionId 0 >>= (@?= Right True)
    pure (provider, marker)
  performGC
  Provider.confirmTransaction closed transactionId 0 >>= (@?= Left Provider.ProviderClosed)
  waitFor "callback registration finalization" (takeMVar finalized)
  deRefWeak weak >>= assertBool "final native release frees the StablePtr root" . isNothing

-- Cancellation of a blocked handler must join native work before propagating.
checkCancellation :: Int -> IO ()
checkCancellation baseline = do
  entered <- newEmptyMVar
  blocked <- newEmptyMVar
  finished <- newEmptyMVar
  before <- Provider.completedNativeCalls
  Provider.withProvider
    (\_ _ -> putMVar entered () >> takeMVar blocked >> pure (Right True))
    $ \provider -> do
      worker <- forkFinally (Provider.confirmTransaction provider transactionId 0) (putMVar finished)
      waitFor "callback entry" (takeMVar entered)
      outcome <- waitFor "cancellation unwind" (killThread worker >> takeMVar finished)
      case outcome of
        Left cause -> fromException cause @?= Just ThreadKilled
        Right value -> assertFailure ("cancelled callback returned " ++ show value)
      Provider.completedNativeCalls >>= (@?= before + 1)
      Provider.liveCallbackContexts >>= (@?= baseline + 1)
  Provider.liveCallbackContexts >>= (@?= baseline)

-- Independent providers isolate exceptions; closing a busy handle leaves its
-- operation reference alive until the callback has finished.
checkConcurrencyAndClose :: Int -> IO ()
checkConcurrencyAndClose baseline = do
  entered <- newEmptyMVar
  resume <- newEmptyMVar
  finished <- newEmptyMVar
  failSecond <- newIORef True
  Provider.withProvider
    (\_ _ -> putMVar entered () >> takeMVar resume >> pure (Right True))
    $ \first ->
      Provider.withProvider
        ( \_ _ -> do
            failNow <- readIORef failSecond
            if failNow then throwIO CallbackException else pure (Right False)
        )
        $ \second -> do
          _ <- forkFinally (Provider.confirmTransaction first transactionId 0) (putMVar finished)
          waitFor "concurrent callback entry" (takeMVar entered)
          isolated <- try (Provider.confirmTransaction second transactionId 0)
          isolated @?= Left CallbackException
          writeIORef failSecond False
          Provider.confirmTransaction second transactionId 0 >>= (@?= Right False)
          Provider.confirmTransaction first transactionId 0 >>= (@?= Left Provider.ProviderBusy)
          closeTwice first
          Provider.liveCallbackContexts >>= (@?= baseline + 2)
          Provider.confirmTransaction first transactionId 0 >>= (@?= Left Provider.ProviderClosed)
          putMVar resume ()
          outcome <- waitFor "closed provider operation" (takeMVar finished)
          case outcome of
            Left cause -> assertFailure (show (cause :: SomeException))
            Right value -> value @?= Right True
          Provider.liveCallbackContexts >>= (@?= baseline + 1)
  Provider.liveCallbackContexts >>= (@?= baseline)

-- Recursive use of the same provider rejects overlap rather than deadlocking.
checkReentry :: IO ()
checkReentry = do
  owner <- newIORef Nothing
  Provider.withProvider
    ( \_ _ -> do
        current <- readIORef owner
        case current of
          Nothing -> assertFailure "missing test owner"
          Just provider -> Provider.confirmTransaction provider transactionId 0 >>= (@?= Left Provider.ProviderBusy)
        pure (Right True)
    )
    $ \provider -> do
      writeIORef owner (Just provider)
      result <- waitFor "reentrant operation rejection" (Provider.confirmTransaction provider transactionId 0)
      assertBool "outer callback succeeds after rejected reentry" (result == Right True)
  -- Do not keep the closed handle in a test-owned reference unnecessarily.
  writeIORef owner Nothing

-- Deterministic unit coverage of cancellation arriving before native dispatch.
-- The normal path above exercises the same trampoline through real cardano-c.
checkPendingCancellation :: IO ()
checkPendingCancellation = do
  calls <- newIORef (0 :: Int)
  control <- Bridge.newCallbackControl
  Bridge.beginCallbackOperation control Unmasked
  Bridge.cancelCallbackOperation control (toException ThreadKilled)
  let state = Bridge.newCallbackState (\_ _ -> modifyIORef' calls (+ 1) >> pure (Right True)) control
  bracket (newStablePtr state) freeStablePtr $ \stable ->
    ByteString.useAsCStringLen transactionId $ \(hash, size) ->
      alloca $ \confirmed ->
        allocaBytes 1024 $ \diagnostic -> do
          replicateM_ 2 $ do
            code <- Bridge.confirmationCallback stable (castPtr hash) (fromIntegral size) 0 confirmed diagnostic 1024
            code @?= FFI.failure
            peek confirmed >>= (@?= 0)
          readIORef calls >>= (@?= 0)
          result <- try (Bridge.rethrowCallbackException control)
          result @?= Left ThreadKilled
  Bridge.finishCallbackOperation control

-- A handler masking cancellation keeps native ownership until explicitly resumed.
checkDelayedCancellation :: Int -> IO ()
checkDelayedCancellation baseline = do
  entered <- newEmptyMVar
  resume <- newEmptyMVar
  finished <- newEmptyMVar
  before <- Provider.completedNativeCalls
  Provider.withProvider
    (\_ _ -> uninterruptibleMask_ (putMVar entered () >> takeMVar resume >> pure (Right True)))
    $ \provider -> do
      worker <- forkFinally (Provider.confirmTransaction provider transactionId 0) (putMVar finished)
      waitFor "masked callback entry" (takeMVar entered)
      -- Delivery to the initiating caller occurs now. Its cleanup must retain
      -- native state until the deliberately masked handler is released below.
      waitFor "masked callback cancellation request" (killThread worker)
      tryReadMVar finished >>= assertBool "caller still awaits native unwind" . isNothing
      Provider.completedNativeCalls >>= (@?= before)
      closeTwice provider
      Provider.liveCallbackContexts >>= (@?= baseline + 1)
      putMVar resume ()
      outcome <- waitFor "masked callback safe unwind" (takeMVar finished)
      case outcome of
        Left cause -> fromException cause @?= Just ThreadKilled
        Right value -> assertFailure ("masked cancellation returned " ++ show value)
      Provider.completedNativeCalls >>= (@?= before + 1)
  Provider.liveCallbackContexts >>= (@?= baseline)

-- Either result may win the race, but the next operation must start cleanly.
checkFastCancellationRaces :: IO ()
checkFastCancellationRaces =
  Provider.withProvider (\_ _ -> pure (Right True)) $ \provider ->
    replicateM_ 50 $ do
      finished <- newEmptyMVar
      worker <- forkFinally (Provider.confirmTransaction provider transactionId 0) (putMVar finished)
      outcome <- waitFor "fast callback cancellation race" (killThread worker >> takeMVar finished)
      case outcome of
        Left cause -> fromException cause @?= Just ThreadKilled
        Right value -> value @?= Right True
      -- The next operation has a fresh error/cancellation cell and a released
      -- gate whether the previous cancellation won before or after dispatch.
      Provider.confirmTransaction provider transactionId 0 >>= (@?= Right True)

-- Worker dispatch preserves the initiating caller's masking state.
checkCallerMasking :: IO ()
checkCallerMasking = do
  expected <- newIORef Unmasked
  Provider.withProvider
    ( \_ _ -> do
        actual <- getMaskingState
        readIORef expected >>= (@?= actual)
        pure (Right True)
    )
    $ \provider -> do
      Provider.confirmTransaction provider transactionId 0 >>= (@?= Right True)
      writeIORef expected MaskedInterruptible
      mask_ (Provider.confirmTransaction provider transactionId 0) >>= (@?= Right True)

-- Deterministic 32-byte input, independent of the provider under test.
transactionId :: ByteString.ByteString
transactionId = ByteString.pack [0 .. 31]

-- Exercise handle idempotence even when native ownership is shared.
closeTwice :: Provider.Provider -> IO ()
closeTwice provider = Provider.closeProvider provider >> Provider.closeProvider provider

-- Bound synchronization waits so a broken lifecycle yields a test failure.
waitFor :: String -> IO a -> IO a
waitFor label action = do
  result <- timeout 10000000 action
  case result of
    Nothing -> assertFailure (label ++ " timed out") >> fail label
    Just value -> pure value

-- Capture the marker only in the native-rooted handler after construction.
withMarkedProvider :: IO () -> (Provider.Provider -> Weak (IORef Int) -> IO a) -> IO a
withMarkedProvider finalizer action = do
  marker <- newIORef (0 :: Int)
  weak <- mkWeakIORef marker finalizer
  Provider.withProvider
    (\_ _ -> modifyIORef' marker (+ 1) >> pure (Right True))
    (`action` weak)
