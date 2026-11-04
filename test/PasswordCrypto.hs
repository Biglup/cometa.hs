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
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic public test material only. Vector provenance is recorded in
-- Fixtures/PASSWORD_CRYPTO.md; no live keys or external service is used.
module PasswordCrypto (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Emip3 as Emip3
import qualified Cometa.Crypto.Pbkdf2 as Pbkdf2
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import Cometa.Internal.FFI.Native (success)
import qualified Cometa.Internal.FFI.PasswordCrypto as Native
import Cometa.Internal.Failure (NativeFailure (..))
import qualified Cometa.Internal.Hex as Hex
import Cometa.Internal.Ownership (withOwnedOutput)
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), IOException, evaluate, fromException, throwIO, try)
import Control.Monad (replicateM, replicateM_, void)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek, poke)
import Hedgehog (Property, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import capi unsafe "cardano/buffer.h cardano_buffer_ref"
  cRef :: Ptr Native.Buffer -> IO ()

foreign import capi unsafe "cardano/buffer.h cardano_buffer_unref"
  cUnref :: Ptr (Ptr Native.Buffer) -> IO ()

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Password crypto"
    [ testCase "PBKDF2 native password/salt vector" checkPbkdfVector,
      testCase "PBKDF2 independent binary multi-block vector" checkBinaryVector,
      testCase "PBKDF2 rejects invalid parameters before computation" checkBounds,
      testCase "EMIP3 pinned native decrypt vector" checkNativeEnvelope,
      testCase "EMIP3 independent binary envelope" checkIndependentEnvelope,
      testCase "EMIP3 supports empty plaintext and rejects short envelopes" checkEnvelopeBounds,
      testCase "EMIP3 authenticates salt, nonce, tag and ciphertext" checkTampering,
      testCase "EMIP3 encrypt round trips and copied plaintext survives GC" checkRoundTrips,
      testCase "EMIP3 concurrent operations have independent outputs" checkConcurrentEmip3,
      testCase "plaintext owner is wiped and released after success" checkCleanupSuccess,
      testCase "partial failure owner is wiped and released" checkCleanupFailure,
      testCase "copy exception wipes and releases plaintext owner" checkCleanupException,
      testCase "cancellation wipes and releases plaintext owner" checkCleanupCancellation,
      testCase "PBKDF2 evaluation cancellation unwinds before reuse" checkPbkdfCancellation,
      testCase "PBKDF2 shared concurrent result survives GC" checkSharedPbkdf,
      testProperty "PBKDF2 prefix law across SHA512 block boundary" propPrefix
    ]

checkPbkdfVector :: IO ()
checkPbkdfVector =
  fmap Hex.encodeHex (Pbkdf2.deriveBytes "password" "salt" 1 64)
    @?= Right "867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce"

checkBinaryVector :: IO ()
checkBinaryVector =
  fmap Hex.encodeHex (Pbkdf2.deriveBytes "pass\NULword" "sa\NULlt" 2 65)
    @?= Right "b10b04b1ec0406c23faa6bc0309a13f6d520ebc223bf096e42f6eaa6b6598f5dc6643beb1f5db291e44287bbe755e281a26a93c6c04dc59017b9da06be3742bfcb"

checkBounds :: IO ()
checkBounds = do
  Pbkdf2.deriveBytes "" "" 1 32 @?= Left EmptyPbkdf2Salt
  mapM_ (\count -> Pbkdf2.deriveBytes "" "s" count 32 @?= Left (InvalidPbkdf2Iterations count)) [-1, 0, 4294967296, 2 ^ (64 :: Int)]
  mapM_ (\size -> Pbkdf2.deriveBytes "" "s" 1 size @?= Left (InvalidPbkdf2OutputLength size)) [-1, 0, 274877906881, toInteger (maxBound :: Int) + 1]
  fmap ByteString.length (Pbkdf2.deriveBytes "" "s" 1 1) @?= Right 1
  -- Validate the maximum iteration encoding without executing billions of HMACs.
  Pbkdf2.deriveBytes "" "s" 4294967295 0 @?= Left (InvalidPbkdf2OutputLength 0)

nativeEnvelope :: ByteString
nativeEnvelope = decoded "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000009ce1d7784a05efd109ad89c29fea0775bf085ac03988089b3a93"

independentEnvelope :: ByteString
independentEnvelope = decoded "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2bdbd67fe6279185e5cdcb32a669ae6bb7e9d2de22e9eebbe7f95775"

checkNativeEnvelope :: IO ()
checkNativeEnvelope = do
  Emip3.decryptBytes "password" nativeEnvelope >>= (@?= Right (ByteString.pack [0 .. 9]))
  let emptyPasswordEnvelope = decoded "0430bb0e1941fd9ec98909e766447883b4af77242a81c7ef2ba8d339f0deeae383227e257c0d6f28ad372a1bc9b87a30e3544258b21a2b576746f5fb83746c7a8e1fa37e2ca3"
  Emip3.decryptBytes "" emptyPasswordEnvelope >>= (@?= Right (ByteString.pack [0 .. 9]))

checkIndependentEnvelope :: IO ()
checkIndependentEnvelope = do
  Emip3.decryptBytes "p\NULw" independentEnvelope >>= (@?= Right "hello\NULworld")
  Emip3.decryptBytes "p\NULw" (decoded "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b5b62d7cf9c5d08c8a599f4257d36b254") >>= (@?= Right ByteString.empty)

checkEnvelopeBounds :: IO ()
checkEnvelopeBounds =
  mapM_ (\size -> Emip3.decryptBytes "" (ByteString.replicate size 0) >>= (@?= Left (InvalidEmip3EnvelopeLength size))) [0, 1, 59]

checkTampering :: IO ()
checkTampering = do
  Emip3.decryptBytes "wrong password" independentEnvelope >>= checkAuthenticationFailure
  mapM_ (\position -> Emip3.decryptBytes "p\NULw" (flipByte position independentEnvelope) >>= checkAuthenticationFailure) [0, 31, 32, 43, 44, 59, 60, 70]
  where
    flipByte position bytes = ByteString.take position bytes <> ByteString.singleton (ByteString.index bytes position `xor` 1) <> ByteString.drop (position + 1) bytes

checkAuthenticationFailure :: Either Error ByteString -> IO ()
checkAuthenticationFailure (Left (NativeError operation code _)) = do
  operation @?= "emip3.decryptBytes"
  code @?= Code.GenericFailure
checkAuthenticationFailure _ = assertFailure "authentication did not fail with native generic status"

checkRoundTrips :: IO ()
checkRoundTrips = mapM_ check [("", ""), ("", "x"), ("p\NULw", "hello\NULworld"), ("password", ByteString.pack [0 .. 255])]
  where
    check (password, plaintext) = do
      encrypted <- Emip3.encrypt password plaintext
      case encrypted of
        Left err -> assertFailure (show err)
        Right envelope -> do
          ByteString.length envelope @?= ByteString.length plaintext + 60
          result <- Emip3.decryptBytes password envelope
          replicateM_ 3 (void (Emip3.decryptBytes password envelope))
          performGC
          result @?= Right plaintext

checkConcurrentEmip3 :: IO ()
checkConcurrentEmip3 = do
  gates <- replicateM 4 newEmptyMVar
  let operation = do
        encrypted <- Emip3.encrypt "public password" "public plaintext"
        case encrypted of
          Left err -> pure (Left err)
          Right envelope -> Emip3.decryptBytes "public password" envelope
      start gate = void (forkFinally operation (putMVar gate))
      check result = case result of
        Left _ -> assertFailure "concurrent encryption raised an exception"
        Right plaintext -> plaintext @?= Right "public plaintext"
  mapM_ start gates
  results <- mapM takeMVar gates
  mapM_ check results

-- Retain a test-only alias to inspect zeroization before its final release.
-- The production release still owns exactly one reference; its slot is cleared.
checkedRelease :: IO () -> Ptr (Ptr Native.Buffer) -> IO ()
checkedRelease released slot = do
  pointer <- peek slot
  size <- Native.cSize pointer
  cRef pointer
  Native.cRelease slot
  alloca $ \retained -> do
    poke retained pointer
    bytes <- Native.cData pointer >>= \dataPtr -> ByteString.packCStringLen (castPtr dataPtr, fromIntegral size)
    cUnref retained
    bytes @?= ByteString.replicate (fromIntegral size) 0
  released

withPlaintext :: IO () -> (Ptr Native.Buffer -> IO (Either NativeFailure ())) -> IO (Either NativeFailure ())
withPlaintext released action = ByteString.useAsCStringLen nativeEnvelope $ \(input, size) ->
  ByteString.useAsCStringLen "password" $ \(password, passwordSize) ->
    withOwnedOutput
      "passwordCrypto.cleanup"
      (checkedRelease released)
      (Native.cDecrypt (castPtr input) (fromIntegral size) (castPtr password) (fromIntegral passwordSize))
      action

checkCleanupSuccess :: IO ()
checkCleanupSuccess = do
  releases <- newIORef (0 :: Int)
  result <- withPlaintext (modifyIORef' releases (+ 1)) (\_ -> pure (Right ()))
  result @?= Right ()
  readIORef releases >>= (@?= 1)

checkCleanupFailure :: IO ()
checkCleanupFailure = do
  releases <- newIORef (0 :: Int)
  ByteString.useAsCStringLen nativeEnvelope $ \(input, size) ->
    ByteString.useAsCStringLen "password" $ \(password, passwordSize) -> do
      result <-
        withOwnedOutput
          "passwordCrypto.partial"
          (checkedRelease (modifyIORef' releases (+ 1)))
          ( \slot -> do
              status <- Native.cDecrypt (castPtr input) (fromIntegral size) (castPtr password) (fromIntegral passwordSize) slot
              status @?= success
              pure 1
          )
          (\_ -> pure (Right ()))
      case result of
        Left (NativeFailure _ 1 _) -> pure ()
        _ -> assertFailure "injected failure status was lost"
  readIORef releases >>= (@?= 1)

checkCleanupException :: IO ()
checkCleanupException = do
  releases <- newIORef (0 :: Int)
  result <- try (withPlaintext (modifyIORef' releases (+ 1)) (\_ -> throwIO (userError "injected copy failure"))) :: IO (Either IOException (Either NativeFailure ()))
  case result of
    Left _ -> pure ()
    Right _ -> assertFailure "copy exception did not propagate"
  readIORef releases >>= (@?= 1)

checkCleanupCancellation :: IO ()
checkCleanupCancellation = do
  releases <- newIORef (0 :: Int)
  started <- newEmptyMVar
  blocked <- newEmptyMVar
  finished <- newEmptyMVar
  worker <-
    forkFinally
      (withPlaintext (modifyIORef' releases (+ 1)) (\_ -> putMVar started () >> takeMVar blocked))
      (putMVar finished)
  takeMVar started
  killThread worker
  result <- timeout 5000000 (takeMVar finished)
  case result of
    Just (Left exception) | Just ThreadKilled <- fromException exception -> pure ()
    _ -> assertFailure "cancellation did not propagate"
  readIORef releases >>= (@?= 1)

checkPbkdfCancellation :: IO ()
checkPbkdfCancellation = do
  started <- newEmptyMVar
  finished <- newEmptyMVar
  worker <-
    forkFinally
      (putMVar started () >> evaluate (Pbkdf2.deriveBytes "public test password" "salt" 100000 65))
      (putMVar finished)
  takeMVar started
  killThread worker
  result <- timeout 5000000 (takeMVar finished)
  case result of
    Just (Left exception) | Just ThreadKilled <- fromException exception -> pure ()
    _ -> assertFailure "PBKDF2 cancellation did not propagate"
  checkPbkdfVector

checkSharedPbkdf :: IO ()
checkSharedPbkdf = do
  let shared = Pbkdf2.deriveBytes "shared public test" "public salt" 1000 65
  gates <- replicateM 8 newEmptyMVar
  let start gate = void (forkFinally (evaluate shared) (putMVar gate))
  mapM_ start gates
  results <- mapM takeMVar gates
  performGC
  let check result = case result of
        Left _ -> assertFailure "concurrent derivation raised an exception"
        Right bytes -> fmap ByteString.length bytes @?= Right 65
  mapM_ check results

propPrefix :: Property
propPrefix = property $ do
  password <- forAll (Gen.bytes (Range.linear 0 140))
  salt <- forAll (Gen.bytes (Range.linear 1 40))
  size <- forAll (Gen.integral (Range.linear 1 130))
  let larger = Pbkdf2.deriveBytes password salt 2 130
      smaller = Pbkdf2.deriveBytes password salt 2 size
  fmap (ByteString.take (fromInteger size)) larger === smaller

decoded :: Text -> ByteString
decoded text = fromMaybe ByteString.empty (Hex.decodeHex text)
