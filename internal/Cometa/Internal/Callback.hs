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
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Rooted callback state and exception containment. A native operation and a
-- callback's user action each have one scoped worker. Cancellation targets the
-- user worker; the ABI callback always waits for it before returning to C.
module Cometa.Internal.Callback
  ( -- * Callback state
    ConfirmationHandler,
    CallbackState,
    CallbackControl,
    newCallbackControl,
    newCallbackState,

    -- * Operation lifetime
    beginCallbackOperation,
    finishCallbackOperation,
    cancelCallbackOperation,
    rethrowCallbackException,

    -- * Native entry point
    confirmationCallback,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.FFI.Provider as Native
import Control.Concurrent (ThreadId, forkIOWithUnmask, newEmptyMVar, putMVar, readMVar, takeMVar, throwTo)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (MaskingState (..), SomeException, catch, evaluate, mask, mask_, throwIO, try, uninterruptibleMask_)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CSize)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, nullPtr)
import Foreign.StablePtr (deRefStablePtr)
import Foreign.Storable (poke, pokeByteOff)

-- TYPES ----------------------------------------------------------------------

-- | Timeout is milliseconds; the hash is an owned 32-byte Haskell snapshot.
-- Expected failures return text. Thrown exceptions propagate after C returns.
-- The user action runs on its own Haskell thread, with the initiating caller's
-- masking state. It must finish before the callback and its native call finish.
type ConfirmationHandler = ByteString -> Word64 -> IO (Either Text Bool)

-- | One serialized operation: caller masking state, first callback exception,
-- pending cancellation, and the currently running user worker, respectively.
data Operation = Operation MaskingState (IORef (Maybe SomeException)) (Maybe SomeException) (Maybe ThreadId)

-- | Provider-wide state shared by retained aliases. 'Nothing' means no native
-- operation may invoke the callback; the provider's operation gate enforces this.
newtype CallbackControl = CallbackControl (MVar (Maybe Operation))

-- | Handler and operation state rooted by the native context's stable pointer.
data CallbackState = CallbackState ConfirmationHandler CallbackControl

-- CALLBACK STATE -------------------------------------------------------------

-- | Start with no active operation or retained exception.
newCallbackControl :: IO CallbackControl
newCallbackControl = CallbackControl <$> newMVar Nothing

-- | Pair the handler with the control shared by this provider's aliases.
newCallbackState :: ConfirmationHandler -> CallbackControl -> CallbackState
newCallbackState = CallbackState

-- | Each operation gets a fresh error/cancellation cell. The provider-wide gate
-- prevents overlap; the native-rooted callback reads only the active operation.
beginCallbackOperation :: CallbackControl -> MaskingState -> IO ()
beginCallbackOperation (CallbackControl control) masking = do
  exception <- newIORef Nothing
  modifyMVar_ control (const (pure (Just (Operation masking exception Nothing Nothing))))

-- | Clear operation state after the native worker and callback have joined.
finishCallbackOperation :: CallbackControl -> IO ()
finishCallbackOperation (CallbackControl control) = modifyMVar_ control (const (pure Nothing))

-- | Record cancellation even if the native callback has not started. Only the
-- user worker receives throwTo; a late exception can never enter an ABI thread.
cancelCallbackOperation :: CallbackControl -> SomeException -> IO ()
cancelCallbackOperation (CallbackControl control) cause = do
  target <- modifyMVar control $ \case
    Nothing -> pure (Nothing, Nothing)
    Just (Operation masking exception pending thread) -> do
      let original = fromMaybe cause pending
      pure (Just (Operation masking exception (Just original) thread), (,) original <$> thread)
  maybe (pure ()) (\(original, thread) -> throwTo thread original) target

-- | Consume and rethrow the first saved callback exception after native unwind.
-- The operation must still be active so its exception cell remains reachable.
rethrowCallbackException :: CallbackControl -> IO ()
rethrowCallbackException (CallbackControl control) = mask_ $ do
  cause <- withMVar control $ \case
    Nothing -> pure Nothing
    Just (Operation _ slot _ _) -> do
      current <- readIORef slot
      writeIORef slot Nothing
      pure current
  maybe (pure ()) throwIO cause

-- | Preserve the first exception without overwriting it during later cleanup.
rememberCallbackException :: CallbackControl -> SomeException -> IO ()
rememberCallbackException (CallbackControl control) cause =
  withMVar control $ \case
    Nothing -> pure ()
    Just (Operation _ slot _ _) -> do
      previous <- readIORef slot
      case previous of
        Nothing -> writeIORef slot (Just cause)
        Just _ -> pure ()

-- NATIVE CALLBACK ------------------------------------------------------------

-- | Catch every user exception, including marshaling and lazy results, before
-- returning a native failure. Emergency handling does not render user values.
confirmationCallback :: Native.ConfirmationCallback CallbackState
confirmationCallback stable hash size timeout confirmed diagnostic capacity =
  mask_ $ do
    CallbackState handler exceptions <- deRefStablePtr stable
    let failed (cause :: SomeException) = uninterruptibleMask_ $ do
          rememberCallbackException exceptions cause
          poke confirmed 0
          when (diagnostic /= nullPtr && capacity > 0) $ poke diagnostic 0
          pure Native.failure
    runCallbackWorker
      exceptions
      ( do
          poke confirmed 0
          bytes <- ByteString.packCStringLen (castPtr hash, fromIntegral size)
          result <- handler bytes timeout
          case result of
            Left message -> writeDiagnostic diagnostic capacity message >> pure Native.failure
            Right value -> do
              forced <- evaluate value
              poke confirmed (if forced then 1 else 0)
              pure Native.success
      )
      `catch` failed

-- WORKER LIFETIME ------------------------------------------------------------

-- | The user worker's entire lifetime is enclosed by the ABI callback. Even an
-- unexpected asynchronous exception in the ABI thread cancels and joins this
-- worker before the callback's outer catch can return to C.
runCallbackWorker :: forall a. CallbackControl -> IO a -> IO a
runCallbackWorker (CallbackControl control) action = mask $ \restore -> do
  masking <- callbackMaskingState control
  start <- newEmptyMVar
  finished <- newEmptyMVar :: IO (MVar (Either SomeException a))
  worker <- forkIOWithUnmask $ \unmask -> do
    outcome <- try $ do
      takeMVar start
      case masking of
        Unmasked -> unmask action
        MaskedInterruptible -> mask_ action
        MaskedUninterruptible -> uninterruptibleMask_ action
    putMVar finished outcome

  ( do
      registerCallbackWorker control worker start

      outcome <- restore (readMVar finished)
      modifyMVar_ control $ \current -> pure $ case current of
        Just (Operation state exception cause _) -> Just (Operation state exception cause Nothing)
        Nothing -> Nothing
      either throwIO pure outcome
    )
    `catch` cancelAndJoinWorker worker finished

-- | Check that an operation is active before starting a user worker, preserving
-- an earlier callback exception instead of invoking the handler again.
callbackMaskingState :: MVar (Maybe Operation) -> IO MaskingState
callbackMaskingState control = withMVar control $ \case
  Just (Operation state exception _ _) -> do
    previous <- readIORef exception
    maybe (pure ()) throwIO previous
    pure state
  Nothing -> throwIO (userError "confirmation callback outside its operation")

-- | Publish the worker before opening its gate. Pending cancellation is delivered
-- instead of starting the user action. The caller keeps the ABI thread masked.
registerCallbackWorker :: MVar (Maybe Operation) -> ThreadId -> MVar () -> IO ()
registerCallbackWorker control worker start = do
  pending <- modifyMVar control $ \case
    Just (Operation state exception cause _) -> pure (Just (Operation state exception cause (Just worker)), cause)
    Nothing -> pure (Nothing, Nothing)
  maybe (putMVar start ()) (throwTo worker) pending

-- | Never let cancellation leave the ABI callback while its user worker lives.
cancelAndJoinWorker :: ThreadId -> MVar (Either SomeException a) -> SomeException -> IO b
cancelAndJoinWorker worker finished cause = uninterruptibleMask_ $ do
  throwTo worker cause
  _ <- readMVar finished
  throwIO cause

-- DIAGNOSTICS ----------------------------------------------------------------

-- | Copy UTF-8 bytes into a borrowed C buffer, reserving a trailing NUL.
-- Truncation is by byte capacity and may split a multibyte UTF-8 sequence.
-- A null destination or zero capacity leaves the buffer untouched.
writeDiagnostic :: CString -> CSize -> Text -> IO ()
writeDiagnostic target capacity message = do
  let bytes = Text.encodeUtf8 message
      count = min (ByteString.length bytes) (fromIntegral capacity - 1)
  if target == nullPtr || capacity == 0
    then pure ()
    else ByteString.useAsCString bytes $ \source -> do
      copyBytes target source count
      pokeByteOff target count (0 :: CChar)
