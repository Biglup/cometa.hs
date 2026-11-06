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
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Scoped adopted callback registrations. All contexts participating in one C
-- operation share one native worker; group cancellation signals every callback
-- control and joins that worker before releasing any reference or buffer.
module Cometa.Internal.Runtime
  ( Runtime,
    Context,
    Buffer,
    Dispatch,
    withRuntime,
    withRetained,
    close,
    withOperation,
    withOperations,
    withBytes,
    copyBuffer,
    withOwnedBuffer,
    checkStatus,
    liveContexts,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Internal.Callback as Callback
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.FFI.Native as Status
import Cometa.Internal.FFI.Runtime (Buffer, Context)
import qualified Cometa.Internal.FFI.Runtime as FFI
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (copyStaticText)
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, tryTakeMVar)
import Control.Exception (SomeException, bracket, catch, evaluate, finally, getMaskingState, mask, mask_, onException, throwIO, uninterruptibleMask_)
import Control.Monad (forM, forM_, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import Data.Word (Word32, Word8)
import Foreign.C.Types (CSize)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, freeHaskellFunPtr, nullPtr)
import Foreign.StablePtr (deRefStablePtr, freeStablePtr, newStablePtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | Families own operation identifiers and the complete request/reply schema.
type Dispatch = Word32 -> ByteString -> IO (Either Error ByteString)

data Shared = Shared (MVar ()) Callback.CallbackControl (IORef (Maybe Error))

data Runtime = Runtime (IORef (Maybe (Ptr Context))) Shared

data State = State Dispatch Callback.CallbackControl (IORef (Maybe Error))

-- DEFINITIONS ----------------------------------------------------------------

-- | Success adopts callback handles in C; failure leaves cleanup with Haskell.
-- Continuation cleanup waits until every operation using this handle has joined.
withRuntime :: Dispatch -> (Runtime -> IO (Either Error a)) -> IO (Either Error a)
withRuntime dispatch action = mask $ \restore -> do
  acquired <- acquire dispatch
  case acquired of
    Left failure -> pure (Left failure)
    Right runtime -> restore (action runtime) `finally` closeWaiting runtime

-- | An alias owns an independent reference but shares callback operation state.
-- Acquisition during an active operation fails fast instead of racing refcounts.
withRetained :: Runtime -> (Runtime -> IO (Either Error a)) -> IO (Either Error a)
withRetained original action = mask $ \restore -> do
  acquired <- retain original
  case acquired of
    Left failure -> pure (Left failure)
    Right alias -> restore (action alias) `finally` closeWaiting alias

acquire :: Dispatch -> IO (Either Error Runtime)
acquire dispatch = do
  control <- Callback.newCallbackControl
  expected <- newIORef Nothing
  gate <- newMVar ()
  stable <- newStablePtr (State dispatch control expected)
  fun <- FFI.wrapCallback callback `onException` freeStablePtr stable
  let freeRegistration = freeHaskellFunPtr fun >> freeStablePtr stable
  alloca $ \slot -> do
    poke slot nullPtr
    result <- checkStatus "runtime.acquire" =<< (FFI.cNew stable fun slot `onException` freeRegistration)
    case result of
      Left failure -> freeRegistration >> pure (Left failure)
      Right () -> do
        pointer <- peek slot
        if pointer == nullPtr
          then freeRegistration >> pure (Left (NativeContractViolation "runtime.acquire"))
          else (do handle <- newIORef (Just pointer); pure (Right (Runtime handle (Shared gate control expected)))) `onException` FFI.cRelease pointer

retain :: Runtime -> IO (Either Error Runtime)
retain (Runtime handle shared@(Shared gate _ _)) = do
  entered <- tryTakeMVar gate
  case entered of
    Nothing -> pure (Left RuntimeBusy)
    Just () ->
      ( do
          current <- readIORef handle
          case current of
            Nothing -> pure (Left RuntimeClosed)
            Just pointer -> do
              FFI.cRef pointer
              (Right . (`Runtime` shared) <$> newIORef (Just pointer)) `onException` FFI.cRelease pointer
      )
        `finally` putMVar gate ()

-- | Closing while active returns busy. Scope cleanup waits instead. This rule
-- serializes native non-atomic reference transitions, including factory adoption.
close :: Runtime -> IO (Either Error ())
close runtime@(Runtime _ (Shared gate _ _)) = mask_ $ do
  entered <- tryTakeMVar gate
  case entered of
    Nothing -> pure (Left RuntimeBusy)
    Just () -> (releaseHandle runtime >> pure (Right ())) `finally` putMVar gate ()

closeWaiting :: Runtime -> IO ()
closeWaiting runtime@(Runtime _ (Shared gate _ _)) = uninterruptibleMask_ $ do
  takeMVar gate
  releaseHandle runtime `finally` putMVar gate ()

releaseHandle :: Runtime -> IO ()
releaseHandle (Runtime handle _) = do
  current <- readIORef handle
  writeIORef handle Nothing
  maybe (pure ()) FFI.cRelease current

-- | One context is the one-element grouped operation, never a nested worker.
withOperation :: Runtime -> (Ptr Context -> IO (Either Error a)) -> IO (Either Error a)
withOperation runtime action = withOperations [runtime] $ \case
  [pointer] -> action pointer
  _ -> pure (Left (NativeContractViolation "runtime.withOperation"))

-- | Acquire unique gates without blocking, then retain all input handles.
-- Repeated aliases share one callback control. A busy/closed member runs no C.
-- Factories and native owner cleanup must stay inside the supplied operation.
withOperations :: [Runtime] -> ([Ptr Context] -> IO (Either Error a)) -> IO (Either Error a)
withOperations runtimes action = do
  -- Force the supplied list and abstract handle constructors before acquiring
  -- any gates; a lazy group argument must not strand an ownership obligation.
  mapM_ evaluate runtimes
  masking <- getMaskingState
  mask $ \restore -> do
    acquired <- acquireGroup runtimes
    case acquired of
      Left failure -> pure (Left failure)
      Right (pointers, shared) ->
        ( do
            forM_ shared $ \(Shared _ control expected) -> writeIORef expected Nothing >> Callback.beginCallbackOperation control masking
            finished <- newEmptyMVar
            let native = do
                  result <- action pointers
                  mapM_ (\(Shared _ control _) -> Callback.rethrowCallbackException control) shared
                  errors <- mapM (\(Shared _ _ slot) -> readIORef slot) shared
                  pure $ case result of
                    Right _ -> result
                    Left _ -> maybe result Left (listToMaybe (catMaybes errors))
            _ <- forkFinally native (putMVar finished)
            outcome <- restore (readMVar finished) `catch` cancelGroup shared finished
            either throwIO pure outcome
        )
          `finally` (mapM_ (\(Shared _ control _) -> Callback.finishCallbackOperation control) shared >> releaseGroup pointers shared)

acquireGroup :: [Runtime] -> IO (Either Error ([Ptr Context], [Shared]))
acquireGroup = go [] []
  where
    go pointers shared [] = pure (Right (reverse pointers, reverse shared))
    go pointers shared (Runtime handle item@(Shared gate _ _) : rest) = do
      entered <- if any (sameGate gate) shared then pure (Just ()) else tryTakeMVar gate
      case entered of
        Nothing -> releaseGroup pointers shared >> pure (Left RuntimeBusy)
        Just () -> do
          let owners = if any (sameGate gate) shared then shared else item : shared
          current <- readIORef handle
          case current of
            Nothing -> releaseGroup pointers owners >> pure (Left RuntimeClosed)
            Just pointer -> FFI.cRef pointer >> go (pointer : pointers) owners rest
    sameGate gate (Shared candidate _ _) = gate == candidate

releaseGroup :: [Ptr Context] -> [Shared] -> IO ()
releaseGroup pointers shared = do
  mapM_ FFI.cRelease pointers
  forM_ shared $ \(Shared gate _ _) -> putMVar gate ()

cancelGroup :: [Shared] -> MVar (Either SomeException a) -> SomeException -> IO b
cancelGroup shared finished cause = uninterruptibleMask_ $ do
  -- throwTo is synchronous: independent senders ensure a masked worker cannot
  -- delay cancellation of another context whose finalizer lets it unwind.
  senders <- forM shared $ \(Shared _ control _) -> do
    completed <- newEmptyMVar
    _ <- forkFinally (Callback.cancelCallbackOperation control cause) (putMVar completed)
    pure completed
  _ <- readMVar finished
  mapM_ readMVar senders
  throwIO cause

-- | The complete callback decode/action/encode/copy runs inside the protected
-- user worker. Only an owned native buffer crosses back to C on success.
callback :: FFI.Callback State
callback stable operation input size output diagnostic capacity = mask_ $ do
  poke output nullPtr
  State dispatch control expected <- deRefStablePtr stable
  let failed (cause :: SomeException) = uninterruptibleMask_ $ do
        Callback.rememberCallbackException control cause
        when (diagnostic /= nullPtr && capacity > 0) (poke diagnostic 0)
        pure 1
  Callback.runCallbackWorker
    control
    ( do
        writeIORef expected Nothing
        bytes <- if size == 0 then pure B.empty else B.packCStringLen (castPtr input, fromIntegral size)
        result <- dispatch operation bytes
        case result of
          Left failure -> do
            _ <- evaluate (length (show failure))
            writeIORef expected (Just failure)
            when (diagnostic /= nullPtr && capacity > 0) (poke diagnostic 0)
            pure 1
          Right reply -> withBytes reply $ \pointer count -> FFI.cBufferNew pointer count output
    )
    `catch` failed

-- | Byte storage stays alive for the entire synchronous call.
withBytes :: ByteString -> (Ptr Word8 -> CSize -> IO a) -> IO a
withBytes bytes action = B.useAsCStringLen bytes $ \(pointer, size) -> action (castPtr pointer) (fromIntegral size)

-- | Copy borrowed public bytes while the native owner is still live.
copyBuffer :: Text -> Ptr Buffer -> IO (Either Error ByteString)
copyBuffer operation buffer
  | buffer == nullPtr = pure (Left (NativeContractViolation operation))
  | otherwise = do
      size <- FFI.cBufferSize buffer
      bytes <- FFI.cBufferData buffer
      if toInteger size > toInteger (maxBound :: Int) || (bytes == nullPtr && size /= 0)
        then pure (Left (NativeContractViolation operation))
        else if size == 0 then pure (Right B.empty) else Right <$> B.packCStringLen (castPtr bytes, fromIntegral size)

-- | Initialize, adopt, copy and release an owned public buffer on every exit.
withOwnedBuffer :: Text -> (Ptr (Ptr Buffer) -> IO Status.NativeCode) -> IO (Either Error ByteString)
withOwnedBuffer operation call = alloca $ \slot -> bracket (poke slot nullPtr >> pure slot) FFI.cBufferRelease $ \output -> do
  result <- call output >>= checkStatus operation
  case result of
    Left failure -> pure (Left failure)
    Right () -> peek output >>= copyBuffer operation

-- | Preserve native status and copy its static diagnostic before returning.
checkStatus :: Text -> Status.NativeCode -> IO (Either Error ())
checkStatus operation code
  | code == Status.success = pure (Right ())
  | otherwise = do
      message <- Status.cErrorMessage code >>= copyStaticText
      pure (Left (fromNativeFailure (NativeFailure operation (toInteger code) message)))

-- | Test-only count of contexts rooting runtime handles.
liveContexts :: IO Int
liveContexts = fromIntegral <$> FFI.cLiveContexts
