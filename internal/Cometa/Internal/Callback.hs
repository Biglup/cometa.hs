{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Rooted callback state and exception containment. A native operation and a
-- callback's user action each have one scoped worker. Cancellation targets the
-- user worker; the ABI callback always waits for it before returning to C.
module Cometa.Internal.Callback
  ( ConfirmationHandler,
    CallbackState,
    CallbackControl,
    newCallbackControl,
    newCallbackState,
    beginCallbackOperation,
    finishCallbackOperation,
    cancelCallbackOperation,
    rethrowCallbackException,
    confirmationCallback,
  )
where

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

-- | Timeout is milliseconds; the hash is an owned 32-byte Haskell snapshot.
-- Expected failures return text. Thrown exceptions propagate after C returns.
-- The user action runs on its own Haskell thread, with the initiating caller's
-- masking state. It must finish before the callback and its native call finish.
type ConfirmationHandler = ByteString -> Word64 -> IO (Either Text Bool)

data Operation = Operation MaskingState (IORef (Maybe SomeException)) (Maybe SomeException) (Maybe ThreadId)

newtype CallbackControl = CallbackControl (MVar (Maybe Operation))

data CallbackState = CallbackState ConfirmationHandler CallbackControl

newCallbackControl :: IO CallbackControl
newCallbackControl = CallbackControl <$> newMVar Nothing

newCallbackState :: ConfirmationHandler -> CallbackControl -> CallbackState
newCallbackState = CallbackState

-- Each operation gets a fresh error/cancellation cell. The provider-wide gate
-- prevents overlap; the native-rooted callback reads only the active operation.
beginCallbackOperation :: CallbackControl -> MaskingState -> IO ()
beginCallbackOperation (CallbackControl control) masking = do
  exception <- newIORef Nothing
  modifyMVar_ control (const (pure (Just (Operation masking exception Nothing Nothing))))

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

rethrowCallbackException :: CallbackControl -> IO ()
rethrowCallbackException (CallbackControl control) = mask_ $ do
  cause <- withMVar control $ \case
    Nothing -> pure Nothing
    Just (Operation _ slot _ _) -> do
      current <- readIORef slot
      writeIORef slot Nothing
      pure current
  maybe (pure ()) throwIO cause

rememberCallbackException :: CallbackControl -> SomeException -> IO ()
rememberCallbackException (CallbackControl control) cause =
  withMVar control $ \case
    Nothing -> pure ()
    Just (Operation _ slot _ _) -> do
      previous <- readIORef slot
      case previous of
        Nothing -> writeIORef slot (Just cause)
        Just _ -> pure ()

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

-- The user worker's entire lifetime is enclosed by the ABI callback. Even an
-- unexpected asynchronous exception in the ABI thread cancels and joins this
-- worker before the callback's outer catch can return to C.
runCallbackWorker :: forall a. CallbackControl -> IO a -> IO a
runCallbackWorker (CallbackControl control) action = mask $ \restore -> do
  masking <- withMVar control $ \case
    Just (Operation state exception _ _) -> do
      previous <- readIORef exception
      maybe (pure ()) throwIO previous
      pure state
    Nothing -> throwIO (userError "confirmation callback outside its operation")
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
  let cancelAndJoin (cause :: SomeException) = uninterruptibleMask_ $ do
        throwTo worker cause
        _ <- readMVar finished
        throwIO cause
  ( do
      pending <- modifyMVar control $ \case
        Just (Operation state exception cause _) -> pure (Just (Operation state exception cause (Just worker)), cause)
        Nothing -> pure (Nothing, Nothing)
      maybe (putMVar start ()) (throwTo worker) pending
      outcome <- restore (readMVar finished)
      modifyMVar_ control $ \current -> pure $ case current of
        Just (Operation state exception cause _) -> Just (Operation state exception cause Nothing)
        Nothing -> Nothing
      either throwIO pure outcome
    )
    `catch` cancelAndJoin

writeDiagnostic :: CString -> CSize -> Text -> IO ()
writeDiagnostic target capacity message = do
  let bytes = Text.encodeUtf8 message
      count = min (ByteString.length bytes) (fromIntegral capacity - 1)
  if target == nullPtr || capacity == 0
    then pure ()
    else ByteString.useAsCString bytes $ \source -> do
      copyBytes target source count
      pokeByteOff target count (0 :: CChar)
