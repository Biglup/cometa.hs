{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle regression tests against real native hash allocations. Injectable
-- acquisition and release steps exercise failures around the same owned slot.
module Ownership (tests) where

import qualified Cometa.Internal.FFI.Native as Native
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (copyHashResult, withOwnedOutput)
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), IOException, bracket, fromException, throwIO, try)
import Control.Monad (replicateM_)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- These imports stay test-only: they make a second ownership obligation visible
-- without exposing reference-count operations through the public Haskell API.
foreign import capi unsafe "cardano/crypto/blake2b_hash.h cardano_blake2b_hash_ref"
  cRef :: Ptr Native.NativeHash -> IO ()

foreign import capi unsafe "cardano/crypto/blake2b_hash.h cardano_blake2b_hash_refcount"
  cRefCount :: Ptr Native.NativeHash -> IO CSize

tests :: TestTree
tests =
  testGroup
    "Owned output scopes"
    [ testCase "copied hash survives release, allocations, and GC" $ do
        result <- copyHashResult "ownership.snapshot" allocateHash
        replicateM_ 100 $ do
          _ <- copyHashResult "ownership.churn" allocateHash
          pure ()
        performGC

        result @?= Right expectedHash,
      testCase "success releases exactly once after the action" $ do
        releases <- newIORef 0
        result <- withOwnedOutput "ownership.success" (countedRelease releases) allocateHash $ \hash -> do
          readIORef releases >>= (@?= 0)
          cRefCount hash >>= (@?= 1)
          pure (Right ())
        result @?= Right ()
        readIORef releases >>= (@?= 1),
      testCase "native failure after allocation releases partial output" $ do
        releases <- newIORef 0
        -- CARDANO_ERROR_INVALID_ARGUMENT in the pinned cardano/error.h.
        let acquire slot = allocateHash slot >> pure 7
        result <- withOwnedOutput "ownership.failure" (countedRelease releases) acquire unexpectedAction
        case result of
          Left (NativeFailure operation code message) -> do
            operation @?= "ownership.failure"
            code @?= 7
            message @?= "Invalid argument"
          other -> assertFailure (show other)
        readIORef releases >>= (@?= 1),
      testCase "action exception releases exactly once" $ do
        releases <- newIORef 0
        expectException $
          withOwnedOutput "ownership.action" (countedRelease releases) allocateHash $ \_ ->
            throwIO (userError "injected action failure")
        readIORef releases >>= (@?= 1),
      testCase "acquisition exception after allocation releases exactly once" $ do
        releases <- newIORef 0
        let acquire slot = allocateHash slot >> throwIO (userError "injected acquisition failure")
        expectException (withOwnedOutput "ownership.acquire" (countedRelease releases) acquire unexpectedAction)
        readIORef releases >>= (@?= 1),
      testCase "asynchronous cancellation after allocation releases before propagation" $ do
        releases <- newIORef 0
        ready <- newEmptyMVar
        blocked <- newEmptyMVar
        finished <- newEmptyMVar
        let acquire slot = do
              code <- allocateHash slot
              putMVar ready ()
              _ <- takeMVar blocked
              pure code

        worker <- forkFinally (withOwnedOutput "ownership.cancel" (countedRelease releases) acquire unexpectedAction) (putMVar finished)
        started <- timeout 5000000 (takeMVar ready)
        case started of
          Nothing -> killThread worker >> assertFailure "allocation did not finish"
          Just () -> killThread worker

        completed <- timeout 5000000 (takeMVar finished)
        case completed of
          Just (Left exception) -> fromException exception @?= Just ThreadKilled
          _ -> assertFailure "cancellation did not propagate after cleanup"
        readIORef releases >>= (@?= 1),
      testCase "retained reference survives non-nulling unref without double release" $
        alloca $ \retained ->
          bracket (poke retained nullPtr) (const (Native.cUnref retained)) $ \() -> do
            releases <- newIORef 0
            leftNonNull <- newIORef False
            let acquire slot = do
                  code <- allocateHash slot
                  hash <- peek slot
                  cRef hash
                  poke retained hash
                  pure code
                release slot = do
                  countedRelease releases slot
                  pointer <- peek slot
                  writeIORef leftNonNull (pointer /= nullPtr)

            result <- withOwnedOutput "ownership.retained" release acquire (const (pure (Right ())))
            result @?= Right ()
            readIORef releases >>= (@?= 1)
            readIORef leftNonNull >>= (@?= True)
            hash <- peek retained
            cRefCount hash >>= (@?= 1)
            Native.cSize hash >>= (@?= 32),
      testCase "null success is rejected without invoking destructor" $ do
        releases <- newIORef 0
        result <- withOwnedOutput "ownership.null" (countedRelease releases) (const (pure Native.success)) unexpectedAction
        result @?= Left (NativeContractFailure "ownership.null")
        readIORef releases >>= (@?= 0),
      testCase "failure before output allocation does not invoke destructor" $ do
        releases <- newIORef 0
        let acquire slot = do
              peek slot >>= (@?= nullPtr)
              throwIO (userError "injected failure before allocation")
        expectException (withOwnedOutput "ownership.empty" (countedRelease releases) acquire unexpectedAction)
        readIORef releases >>= (@?= 0)
    ]

-- Allocate a real native digest only after checking the helper initialized its
-- output slot. Assertions distinguish fixture setup failures from cleanup bugs.
allocateHash :: Ptr (Ptr Native.NativeHash) -> IO Native.NativeCode
allocateHash slot = do
  peek slot >>= (@?= nullPtr)
  ByteString.useAsCStringLen "abc" $ \(input, size) -> do
    code <- Native.cCompute (castPtr input) (fromIntegral size) 32 slot
    code @?= Native.success
    pure code

-- Count release attempts independently of whether native unref nulls the slot.
countedRelease :: IORef Int -> Ptr (Ptr Native.NativeHash) -> IO ()
countedRelease releases slot = do
  modifyIORef' releases (+ 1)
  Native.cUnref slot

-- Failed acquisition must never hand a pointer to the borrowed action.
unexpectedAction :: Ptr Native.NativeHash -> IO (Either NativeFailure ())
unexpectedAction _ = assertFailure "action ran without successful acquisition" >> pure (Right ())

-- Catch only the injected IO exception; assertion failures must still escape.
expectException :: IO (Either NativeFailure ()) -> IO ()
expectException action = do
  result <- try action :: IO (Either IOException (Either NativeFailure ()))
  case result of
    Left _ -> pure ()
    Right value -> assertFailure ("expected injected exception, got " ++ show value)

-- Independently checked using Python hashlib.blake2b(b"abc", digest_size=32).
expectedHash :: ByteString.ByteString
expectedHash = ByteString.pack [189, 221, 129, 60, 99, 66, 57, 114, 49, 113, 239, 63, 238, 152, 87, 155, 148, 150, 78, 59, 177, 203, 62, 66, 114, 98, 200, 192, 104, 213, 35, 25]
