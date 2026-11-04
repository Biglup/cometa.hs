{-# OPTIONS_HADDOCK hide #-}

-- | Private confirmation adapter and scoped native ownership. This establishes
-- callback mechanics, not a public provider API. Handles close deterministically;
-- retaining creates an independent obligation and an operation temporarily owns
-- another reference. Native context destruction owns runtime-handle cleanup.
module Cometa.Internal.Provider
  ( -- * Scoped handles
    Provider,
    ProviderError (..),
    ConfirmationHandler,
    withProvider,
    withRetainedProvider,
    closeProvider,

    -- * Confirmation
    confirmTransaction,

    -- * Lifecycle evidence
    liveCallbackContexts,
    completedNativeCalls,
  )
where

import Cometa.Internal.Callback (CallbackControl, ConfirmationHandler)
import qualified Cometa.Internal.Callback as Callback
import qualified Cometa.Internal.FFI.Native as Native
import qualified Cometa.Internal.FFI.Provider as FFI
import Cometa.Internal.Ownership (copyStaticText)
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (Exception, SomeException, bracket, catch, evaluate, finally, getMaskingState, mask, mask_, onException, throwIO, uninterruptibleMask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Word (Word64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, freeHaskellFunPtr, nullPtr)
import Foreign.StablePtr (freeStablePtr, newStablePtr)
import Foreign.Storable (peek, poke)

-- | Expected adapter failures. Acquisition failure is raised as an exception;
-- confirmation returns these failures explicitly. User exceptions stay original.
data ProviderError
  = -- | This handle has already released its reference.
    ProviderClosed
  | -- | An operation is already active on this provider or a retained alias.
    ProviderBusy
  | -- | Supplied transaction ID byte length; exactly 32 bytes are required.
    InvalidTransactionIdLength !Int
  | -- | Exact native status and a diagnostic copied before owner release.
    ProviderNativeFailure !Integer !Text
  deriving (Eq, Show)

instance Exception ProviderError

-- | All reference-count transitions for aliases of one native object share this
-- lock. Neither it nor the operation gate is held while running user callbacks.
-- The fields are the refcount lock, operation gate, and callback control. The
-- gate's occupied bit stays set; reentry fails instead of blocking.
data Shared = Shared (MVar ()) (IORef Bool) CallbackControl

-- | One independently closable reference plus shared alias synchronization.
-- Keeping a Haskell handle after its scope ends does not retain native ownership.
data Provider = Provider (IORef (Maybe (Ptr FFI.NativeProvider))) Shared

-- | Acquire one provider reference and close it on every exit. The native
-- context roots the handler until the last retained reference is released.
-- Construction failures raise 'ProviderError'; user exceptions are preserved.
withProvider :: ConfirmationHandler -> (Provider -> IO a) -> IO a
withProvider handler = bracket (acquireProvider handler) closeProvider

-- | Give an independent scoped native reference to the continuation. Closing
-- the original handle leaves this handle usable; both share the operation gate.
withRetainedProvider :: Provider -> (Provider -> IO a) -> IO a
withRetainedProvider provider = bracket acquire closeProvider
  where
    acquire = mask_ $ do
      reference <- acquireReference provider
      case reference of
        Left failure -> throwIO failure
        Right pointer -> do
          let Provider _ shared = provider
          (Provider <$> newIORef (Just pointer) <*> pure shared)
            `onException` releaseReference shared pointer

-- | Idempotently invalidate this handle, regardless of whether native unref
-- leaves its local pointer non-null because another owner still exists.
closeProvider :: Provider -> IO ()
closeProvider (Provider handle (Shared lifetime _ _)) =
  uninterruptibleMask_ $ withMVar lifetime $ \() -> do
    pointer <- readIORef handle
    writeIORef handle Nothing
    maybe (pure ()) FFI.cRelease pointer

-- | Confirm through the synchronous native provider using scoped workers.
-- Independent providers can overlap. Overlap or callback reentry on aliases of
-- this provider returns ProviderBusy. A closed handle returns ProviderClosed.
--
-- Cancellation stops awaiting the result, asks the user worker to unwind, and
-- joins the native worker before rethrowing the original exception. A handler
-- that masks cancellation, or native code that has not returned, delays that
-- unwind; neither its native state nor its buffers can be released early.
confirmTransaction :: Provider -> ByteString -> Word64 -> IO (Either ProviderError Bool)
confirmTransaction provider hash timeout
  | ByteString.length hash /= 32 = pure (Left (InvalidTransactionIdLength (ByteString.length hash)))
  | otherwise = do
      callerMasking <- getMaskingState
      withReference provider $ \pointer ->
        mask $ \restore -> do
          let Provider _ (Shared _ busy state) = provider
          entered <- atomicModifyIORef' busy (\occupied -> (True, not occupied))
          if not entered
            then pure (Left ProviderBusy)
            else
              ( do
                  Callback.beginCallbackOperation state callerMasking
                  finished <- newEmptyMVar
                  _ <- forkFinally (nativeConfirmation state pointer) (putMVar finished)
                  let cancelAndJoin cause = uninterruptibleMask_ $ do
                        Callback.cancelCallbackOperation state cause
                        _ <- readMVar finished
                        throwIO (cause :: SomeException)
                  outcome <- restore (readMVar finished) `catch` cancelAndJoin
                  either throwIO pure outcome
              )
                `finally` (Callback.finishCallbackOperation state >> writeIORef busy False)
  where
    nativeConfirmation state pointer =
      ByteString.useAsCStringLen hash $ \(bytes, size) ->
        alloca $ \confirmed -> do
          poke confirmed 0
          code <- FFI.cConfirm pointer (castPtr bytes) (fromIntegral size) timeout confirmed
          Callback.rethrowCallbackException state
          if code == Native.success
            then Right . (/= 0) <$> peek confirmed
            else do
              diagnostic <- FFI.cError pointer >>= copyStaticText
              pure (Left (ProviderNativeFailure (toInteger code) diagnostic))

-- | Number of native contexts still rooting Haskell callback registrations.
-- This instrumentation is lifecycle evidence, not a public API contract.
liveCallbackContexts :: IO Int
liveCallbackContexts = fromIntegral <$> FFI.cLiveContexts

-- | Increased by the C shim only after cardano_provider_confirm_transaction and
-- hash cleanup have returned. Used to establish safe exception unwind in tests.
completedNativeCalls :: IO Integer
completedNativeCalls = toInteger <$> FFI.cCompletedCalls

-- | Register runtime handles under masking. Successful native construction
-- adopts both handles; before that transfer, Haskell owns their cleanup.
acquireProvider :: ConfirmationHandler -> IO Provider
acquireProvider handler = mask_ $ do
  exceptions <- Callback.newCallbackControl
  let state = Callback.newCallbackState handler exceptions
  lifetime <- newMVar ()
  busy <- newIORef False
  handle <- newIORef Nothing
  shared <- evaluate (Shared lifetime busy exceptions)
  provider <- evaluate (Provider handle shared)

  stable <- newStablePtr state
  function <- FFI.wrapConfirmation Callback.confirmationCallback `onException` freeStablePtr stable
  let freeRegistration = freeHaskellFunPtr function >> freeStablePtr stable

  alloca $ \output -> do
    poke output nullPtr
    code <- FFI.cNew stable function output `onException` freeRegistration
    if code /= Native.success
      then do
        freeRegistration
        message <- Native.cErrorMessage code >>= copyStaticText
        throwIO (ProviderNativeFailure (toInteger code) message)
      else do
        pointer <- peek output
        -- Success transferred both runtime handles to the native context.
        -- Publication can still allocate; its failure releases the native owner,
        -- whose destructor now owns registration cleanup.
        (writeIORef handle (Just pointer) >> pure provider)
          `onException` (writeIORef handle Nothing >> FFI.cRelease pointer)

-- | Retain an open handle while serializing non-atomic native refcounts.
acquireReference :: Provider -> IO (Either ProviderError (Ptr FFI.NativeProvider))
acquireReference (Provider handle (Shared lifetime _ _)) =
  -- The lock protects only bounded refcount operations. Its holder never runs
  -- user code, so cleanup cannot be cancelled while waiting for this short lock.
  uninterruptibleMask_ $ withMVar lifetime $ \() -> do
    current <- readIORef handle
    case current of
      Nothing -> pure (Left ProviderClosed)
      Just pointer -> FFI.cRef pointer >> pure (Right pointer)

-- | Release one operation reference under the same lock used for retention.
releaseReference :: Shared -> Ptr FFI.NativeProvider -> IO ()
releaseReference (Shared lifetime _ _) pointer =
  uninterruptibleMask_ $ withMVar lifetime $ \() -> FFI.cRelease pointer

-- | Keep the native object alive through the action, even if another alias
-- closes its handle. A closed input handle never runs the action.
withReference :: Provider -> (Ptr FFI.NativeProvider -> IO (Either ProviderError a)) -> IO (Either ProviderError a)
withReference provider action = mask $ \restore -> do
  acquired <- acquireReference provider
  case acquired of
    Left failure -> pure (Left failure)
    Right pointer -> do
      let Provider _ shared = provider
      restore (action pointer) `finally` releaseReference shared pointer
