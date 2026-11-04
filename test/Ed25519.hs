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
{-# LANGUAGE OverloadedStrings #-}

-- | Public Ed25519 values, published known answers and scoped secret lifetimes.
-- All signing material is deterministic test data, never application keys.
module Ed25519 (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.FFI.SigningKey as Native
import qualified Cometa.Internal.Failure as Failure
import Cometa.Internal.Hex (decodeHex, encodeHex)
import qualified Cometa.Internal.SigningKey as Core
import Control.Concurrent (MVar, ThreadId, forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, tryPutMVar, yield)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, bracket, finally, fromException, mask_, throw, throwIO, try)
import Control.Monad (replicateM_, void)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Fixtures.Ed25519 (Vector (..))
import qualified Fixtures.Ed25519 as Fixture
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (poke)
import GHC.Conc (BlockReason (BlockedOnMVar), ThreadStatus (..), threadStatus)
import Hedgehog (Property, PropertyT, evalEither, evalIO, forAll, forAllWith, property, withTests, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- TYPES ----------------------------------------------------------------------

data ScopeException = ScopeException deriving (Eq, Show)

instance Exception ScopeException

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Ed25519"
    [ testCase "published normal and extended known answers" $ mapM_ checkKnownAnswer Fixture.allVectors,
      testCase "altered message, public key and signature fail verification" $ mapM_ checkTampering Fixture.allVectors,
      testCase "public key and signature byte/hex bounds" checkPublicBounds,
      testCase "public hex imports normalize case and reject malformed input" checkPublicHex,
      testCase "normal and extended signing imports reject invalid lengths" checkSigningBounds,
      testCase "unusable expanded scalar fails safely and closes its scope" checkUnusableScalar,
      testCase "signing hex imports reject malformed input without echoing it" checkSigningHex,
      testCase "explicit key exports preserve normal and extended input" $ mapM_ checkExport Fixture.allVectors,
      testCase "closed and escaped signing keys reject every operation" checkClosedKeys,
      testCase "callback Left closes an escaped signing key" checkScopeFailure,
      testCase "scope exception closes an escaped signing key" checkScopeException,
      testCase "scope cancellation closes an escaped signing key" checkScopeCancellation,
      testCase "a deep clone survives closing its source" checkClone,
      testCase "public results survive closed key, native churn and GC" checkSnapshots,
      testCase "throwing message input does not leave a signing key locked" checkMessageException,
      testCase "concurrent signing and close leave no live escaped key" checkSignCloseRaces,
      testCase "native key scope releases one reference after success or exception" checkNativeScopeRelease,
      testCase "cancelled native key scope releases its reference" checkNativeScopeCancellation,
      testCase "close waits for an in-flight native signing operation" checkInFlightClose,
      testCase "clone owns a distinct native allocation" checkNativeClone,
      testProperty "public key byte and hex round trips" propPublicKey,
      testProperty "signature byte and hex round trips" propSignature,
      testProperty "normal sign and verify agree for arbitrary test seeds and messages" propNormalSign,
      testProperty "extended sign and verify agree for arbitrary messages" propExtendedSign
    ]

checkKnownAnswer :: Vector -> IO ()
checkKnownAnswer vector = do
  bytes <- hexBytes (privateHex vector)
  message <- hexBytes (messageHex vector)
  (key, signature) <- requireRight $ withVector vector bytes $ \secret -> do
    public <- SigningKey.publicKey secret
    signed <- SigningKey.sign secret message
    pure ((,) <$> public <*> signed)
  PublicKey.toHex key @?= publicHex vector
  Signature.toHex signature @?= signatureHex vector
  PublicKey.verify key message signature >>= (@?= Right True)
  digest <- requireRight (PublicKey.hash key)
  Blake2b.toHex digest @?= publicHashHex vector
  PublicKey.byteLength key @?= 32
  PublicKey.hexLength key @?= 64
  Signature.byteLength signature @?= 64
  Signature.hexLength signature @?= 128

checkTampering :: Vector -> IO ()
checkTampering vector = do
  key <- requirePure (PublicKey.fromHex (publicHex vector))
  signature <- requirePure (Signature.fromHex (signatureHex vector))
  message <- hexBytes (messageHex vector)
  otherKey <- requirePure (PublicKey.fromBytes (alterFirst (PublicKey.toBytes key)))
  otherSignature <- requirePure (Signature.fromBytes (alterFirst (Signature.toBytes signature)))
  PublicKey.verify key (message <> ByteString.singleton 0) signature >>= (@?= Right False)
  PublicKey.verify otherKey message signature >>= (@?= Right False)
  PublicKey.verify key message otherSignature >>= (@?= Right False)

checkPublicBounds :: IO ()
checkPublicBounds = do
  mapM_ (\size -> PublicKey.fromBytes (ByteString.replicate size 0) @?= Left (InvalidEd25519PublicKeyLength size)) [0, 1, 31, 33, 64]
  mapM_ (\size -> Signature.fromBytes (ByteString.replicate size 0) @?= Left (InvalidEd25519SignatureLength size)) [0, 1, 32, 63, 65, 128]
  -- Public constructors validate encoding length, not curve or signature validity.
  key <- requirePure (PublicKey.fromBytes (ByteString.replicate 32 0))
  signature <- requirePure (Signature.fromBytes (ByteString.replicate 64 0))
  PublicKey.byteLength key @?= 32
  Signature.byteLength signature @?= 64

checkPublicHex :: IO ()
checkPublicHex = do
  let vector = Fixture.normalVector
  key <- requirePure (PublicKey.fromHex (Text.toUpper (publicHex vector)))
  PublicKey.toHex key @?= publicHex vector
  signature <- requirePure (Signature.fromHex (Text.toUpper (signatureHex vector)))
  Signature.toHex signature @?= signatureHex vector
  mapM_ (\input -> PublicKey.fromHex input @?= Left InvalidHex) malformedHex
  mapM_ (\input -> Signature.fromHex input @?= Left InvalidHex) malformedHex
  PublicKey.fromHex (Text.replicate 31 "00") @?= Left (InvalidEd25519PublicKeyLength 31)
  Signature.fromHex (Text.replicate 63 "00") @?= Left (InvalidEd25519SignatureLength 63)

checkSigningBounds :: IO ()
checkSigningBounds = do
  mapM_ (check SigningKey.withNormalKey 32) [0, 1, 31, 33, 64]
  mapM_ (check SigningKey.withExtendedKey 64) [0, 1, 32, 63, 65, 128]
  where
    check constructor expected actual = do
      result <- constructor (ByteString.replicate actual 0) (const (pure (Right ())))
      result @?= Left (InvalidEd25519SigningKeyLength expected actual)

checkUnusableScalar :: IO ()
checkUnusableScalar = do
  escaped <- newIORef Nothing
  result <- SigningKey.withExtendedKey (ByteString.replicate 64 0) $ \key -> do
    writeIORef escaped (Just key)
    public <- SigningKey.publicKey key
    signature <- SigningKey.sign key ByteString.empty
    public @?= Left (failure "ed25519.publicKey")
    signature @?= Left (failure "ed25519.sign")
    pure (Left (failure "ed25519.publicKey") :: Either Error ())
  result @?= Left (failure "ed25519.publicKey")
  readIORef escaped >>= maybe (assertFailure "missing unusable test handle") checkClosed
  checkUnusableScalarRelease
  where
    failure operation = NativeError operation Code.GenericFailure "Generic error"

checkUnusableScalarRelease :: IO ()
checkUnusableScalarRelease = withRetainedNative $ \owner -> do
  result <- Core.withExtendedKey (ByteString.replicate 64 0) $ \key -> do
    _ <- requireRight (Core.withKey key (retainNative owner))
    Core.signBytes key ByteString.empty
  result @?= Right (Left (Core.NativeFailure (Failure.NativeFailure "ed25519.sign" 1 "Generic error")))
  assertSingleReference owner

checkSigningHex :: IO ()
checkSigningHex = do
  mapM_ checkMalformed malformedHex
  mapM_ checkValid [Fixture.normalVector, Fixture.extendedVector]
  where
    checkMalformed input = do
      SigningKey.withNormalKeyHex input (const (pure (Right ()))) >>= (@?= Left InvalidHex)
      SigningKey.withExtendedKeyHex input (const (pure (Right ()))) >>= (@?= Left InvalidHex)
    checkValid vector = do
      let constructor = if isExtended vector then SigningKey.withExtendedKeyHex else SigningKey.withNormalKeyHex
      key <- requireRight $ constructor (Text.toUpper (privateHex vector)) SigningKey.publicKey
      PublicKey.toHex key @?= publicHex vector

checkExport :: Vector -> IO ()
checkExport vector = do
  bytes <- hexBytes (privateHex vector)
  result <- withVector vector bytes $ \key -> do
    SigningKey.byteLength key >>= (@?= Right (ByteString.length bytes))
    SigningKey.hexLength key >>= (@?= Right (Text.length (privateHex vector)))
    exported <- SigningKey.exportBytes key
    encoded <- SigningKey.exportHex key
    pure $ do
      copied <- exported
      hex <- encoded
      pure (copied == bytes && hex == privateHex vector)
  result @?= Right True

checkClosedKeys :: IO ()
checkClosedKeys = mapM_ check [Fixture.normalVector, Fixture.extendedVector]
  where
    check vector = do
      bytes <- hexBytes (privateHex vector)
      escaped <- requireRight $ withVector vector bytes $ \key -> do
        SigningKey.close key
        SigningKey.close key
        checkClosed key
        pure (Right key)
      checkClosed escaped

checkClosed :: SigningKey.SigningKey -> IO ()
checkClosed key = do
  SigningKey.sign key ByteString.empty >>= (@?= Left SigningKeyClosed)
  SigningKey.publicKey key >>= (@?= Left SigningKeyClosed)
  exported <- SigningKey.exportBytes key
  assertClosed exported
  encoded <- SigningKey.exportHex key
  assertClosed encoded
  SigningKey.byteLength key >>= (@?= Left SigningKeyClosed)
  SigningKey.hexLength key >>= (@?= Left SigningKeyClosed)
  SigningKey.withClone key (const (pure (Right ()))) >>= (@?= Left SigningKeyClosed)
  where
    assertClosed result = case result of
      Left failure -> failure @?= SigningKeyClosed
      Right _ -> assertFailure "closed key exported secret material"

checkScopeFailure :: IO ()
checkScopeFailure = do
  bytes <- hexBytes (privateHex Fixture.normalVector)
  escaped <- newIORef Nothing
  result <- SigningKey.withNormalKey bytes $ \key -> do
    writeIORef escaped (Just key)
    pure (Left InvalidHex :: Either Error ())
  result @?= Left InvalidHex
  readIORef escaped >>= maybe (assertFailure "missing escaped test handle") checkClosed

checkScopeException :: IO ()
checkScopeException = do
  bytes <- hexBytes (privateHex Fixture.normalVector)
  escaped <- newIORef Nothing
  result <- try $ SigningKey.withNormalKey bytes $ \key -> do
    writeIORef escaped (Just key)
    throwIO ScopeException
  (result :: Either ScopeException (Either Error ())) @?= Left ScopeException
  readIORef escaped >>= maybe (assertFailure "missing escaped test handle") checkClosed

checkScopeCancellation :: IO ()
checkScopeCancellation = do
  bytes <- hexBytes (privateHex Fixture.normalVector)
  escaped <- newEmptyMVar
  blocked <- newEmptyMVar :: IO (MVar ())
  finished <- newEmptyMVar
  worker <-
    forkFinally
      (SigningKey.withNormalKey bytes $ \key -> putMVar escaped key >> takeMVar blocked >> pure (Right ()))
      (putMVar finished)
  key <- waitFor "signing scope entry" (takeMVar escaped)
  result <- waitFor "signing scope cancellation" (killThread worker >> takeMVar finished)
  case result of
    Left cause -> fromException cause @?= Just ThreadKilled
    Right _ -> assertFailure "cancelled signing scope completed"
  checkClosed key

checkClone :: IO ()
checkClone = do
  let vector = Fixture.extendedVector
  bytes <- hexBytes (privateHex vector)
  message <- hexBytes (messageHex vector)
  result <- SigningKey.withExtendedKey bytes $ \source ->
    SigningKey.withClone source $ \copy -> do
      SigningKey.close source
      checkClosed source
      performGC
      signature <- SigningKey.sign copy message
      pure (Signature.toHex <$> signature)
  result @?= Right (signatureHex vector)

checkSnapshots :: IO ()
checkSnapshots = do
  let vector = Fixture.normalVector
  bytes <- hexBytes (privateHex vector)
  (public, signature) <- requireRight $ SigningKey.withNormalKey bytes $ \key -> do
    performGC
    pub <- SigningKey.publicKey key
    sig <- SigningKey.sign key ByteString.empty
    pure ((,) <$> pub <*> sig)
  replicateM_ 100 $ do
    _ <- requireRight $ SigningKey.withNormalKey bytes (`SigningKey.sign` "temporary native signing allocation")
    pure ()
  performGC
  PublicKey.toHex public @?= publicHex vector
  Signature.toHex signature @?= signatureHex vector
  PublicKey.verify public ByteString.empty signature >>= (@?= Right True)

checkMessageException :: IO ()
checkMessageException = do
  bytes <- hexBytes (privateHex Fixture.normalVector)
  result <- SigningKey.withNormalKey bytes $ \key -> do
    outcome <- try (SigningKey.sign key (throw ScopeException))
    (outcome :: Either ScopeException (Either Error Signature.Signature)) @?= Left ScopeException
    SigningKey.close key
    checkClosed key
    pure (Right ())
  result @?= Right ()

checkSignCloseRaces :: IO ()
checkSignCloseRaces = do
  bytes <- hexBytes (privateHex Fixture.normalVector)
  public <- requirePure (PublicKey.fromHex (publicHex Fixture.normalVector))
  let message = ByteString.replicate 65536 42
  replicateM_ 25 $ do
    result <- SigningKey.withNormalKey bytes $ \key -> do
      started <- newEmptyMVar
      finished <- newEmptyMVar
      _ <- forkFinally (putMVar started () >> SigningKey.sign key message) (putMVar finished)
      waitFor "signing race entry" (takeMVar started)
      SigningKey.close key
      outcome <- waitFor "signing race completion" (takeMVar finished)
      case outcome of
        Left cause -> assertFailure (show (cause :: SomeException))
        Right (Left failure) -> failure @?= SigningKeyClosed
        Right (Right signature) -> PublicKey.verify public message signature >>= (@?= Right True)
      checkClosed key
      pure (Right ())
    result @?= Right ()

checkNativeScopeRelease :: IO ()
checkNativeScopeRelease = do
  bytes <- hexBytes (privateHex Fixture.normalVector)
  withRetainedNative $ \owner -> do
    _ <- requireRight $ Core.withNormalKey bytes $ \key ->
      requireRight (Core.withKey key (retainNative owner))
    assertSingleReference owner
  withRetainedNative $ \owner -> do
    failure <- Core.withNormalKey bytes $ \key -> do
      _ <- requireRight (Core.withKey key (retainNative owner))
      pure (Left Core.InvalidHex :: Either Core.Failure ())
    failure @?= Right (Left Core.InvalidHex)
    assertSingleReference owner
  withRetainedNative $ \owner -> do
    outcome <- try $ Core.withNormalKey bytes $ \key -> do
      _ <- requireRight (Core.withKey key (retainNative owner))
      throwIO ScopeException
    (outcome :: Either ScopeException (Either Core.Failure ())) @?= Left ScopeException
    assertSingleReference owner

checkNativeScopeCancellation :: IO ()
checkNativeScopeCancellation = do
  bytes <- hexBytes (privateHex Fixture.extendedVector)
  withRetainedNative $ \owner -> do
    entered <- newEmptyMVar
    blocked <- newEmptyMVar :: IO (MVar ())
    finished <- newEmptyMVar
    worker <-
      forkFinally
        ( Core.withExtendedKey bytes $ \key -> do
            _ <- requireRight (Core.withKey key (retainNative owner))
            putMVar entered key
            takeMVar blocked
        )
        (putMVar finished)
    key <- waitFor "native key scope entry" (takeMVar entered)
    outcome <- waitFor "native key scope cancellation" (killThread worker >> takeMVar finished)
    case outcome of
      Left cause -> fromException cause @?= Just ThreadKilled
      Right _ -> assertFailure "cancelled native key scope completed"
    Core.withKey key (const (pure (Right ()))) >>= (@?= Left Core.Closed)
    assertSingleReference owner

checkInFlightClose :: IO ()
checkInFlightClose = do
  bytes <- hexBytes (privateHex Fixture.normalVector)
  result <- Core.withNormalKey bytes $ \key -> do
    entered <- newEmptyMVar
    resume <- newEmptyMVar
    signed <- newEmptyMVar
    closed <- newEmptyMVar
    _ <-
      forkFinally
        (Core.withKey key (pausedSign entered resume))
        (putMVar signed)
    ( do
        waitFor "native sign lock entry" (takeMVar entered)
        closer <- forkFinally (Core.close key) (putMVar closed)
        waitFor "close waiting on active signing lock" (waitUntilBlocked closer)
        putMVar resume ()
        outcome <- waitFor "native signing completion" (takeMVar signed)
        signature <- case outcome of
          Left cause -> assertFailure (show (cause :: SomeException)) >> fail "native signer failed"
          Right value -> requirePure value
        encodeHex signature @?= signatureHex Fixture.normalVector
        waitFor "close after native signing" (takeMVar closed) >>= requireThreadSuccess
        Core.withKey key (const (pure (Right ()))) >>= (@?= Left Core.Closed)
      )
      `finally` void (tryPutMVar resume ())
  result @?= Right ()

pausedSign :: MVar () -> MVar () -> Ptr Native.NativeKey -> IO (Either Core.Failure ByteString)
pausedSign entered resume pointer = do
  putMVar entered ()
  takeMVar resume
  performGC
  ByteString.useAsCStringLen ByteString.empty $ \(message, size) ->
    allocaBytes 64 $ \signature -> do
      status <- Native.cSign pointer (castPtr message) (fromIntegral size) signature
      status @?= 0
      bytes <- ByteString.packCStringLen (castPtr signature, 64)
      pure (Right bytes)

checkNativeClone :: IO ()
checkNativeClone = do
  bytes <- hexBytes (privateHex Fixture.extendedVector)
  result <- Core.withExtendedKey bytes $ \source ->
    requireRight $ Core.withClone source $ \copy -> do
      first <- requireRight (Core.withKey source (pure . Right))
      second <- requireRight (Core.withKey copy (pure . Right))
      assertBool "clone shares its native allocation" (first /= second)
      cNativeRefCount first >>= (@?= 1)
      cNativeRefCount second >>= (@?= 1)
  result @?= Right ()

withRetainedNative :: (IORef (Ptr Native.NativeKey) -> IO value) -> IO value
withRetainedNative = bracket (newIORef nullPtr) release
  where
    release owner = do
      pointer <- readIORef owner
      if pointer == nullPtr then pure () else alloca $ \slot -> poke slot pointer >> cNativeUnref slot

retainNative :: IORef (Ptr Native.NativeKey) -> Ptr Native.NativeKey -> IO (Either Core.Failure ())
retainNative owner pointer = mask_ $ do
  cNativeRef pointer
  writeIORef owner pointer
  cNativeRefCount pointer >>= (@?= 2)
  pure (Right ())

assertSingleReference :: IORef (Ptr Native.NativeKey) -> IO ()
assertSingleReference owner = do
  pointer <- readIORef owner
  assertBool "native lifecycle fixture did not retain its reference" (pointer /= nullPtr)
  cNativeRefCount pointer >>= (@?= 1)

waitUntilBlocked :: ThreadId -> IO ()
waitUntilBlocked thread = do
  status <- threadStatus thread
  case status of
    ThreadBlocked BlockedOnMVar -> pure ()
    ThreadRunning -> yield >> waitUntilBlocked thread
    _ -> assertFailure "close did not wait on the active key operation"

requireThreadSuccess :: Either SomeException () -> IO ()
requireThreadSuccess result = case result of
  Right () -> pure ()
  Left cause -> assertFailure (show cause)

propPublicKey :: Property
propPublicKey = withTests 300 $ property $ do
  bytes <- forAll (Gen.bytes (Range.singleton 32))
  key <- evalEither (PublicKey.fromBytes bytes)
  PublicKey.toBytes key === bytes
  PublicKey.fromHex (PublicKey.toHex key) === Right key
  PublicKey.byteLength key === 32
  PublicKey.hexLength key === 64

propSignature :: Property
propSignature = withTests 300 $ property $ do
  bytes <- forAll (Gen.bytes (Range.singleton 64))
  signature <- evalEither (Signature.fromBytes bytes)
  Signature.toBytes signature === bytes
  Signature.fromHex (Signature.toHex signature) === Right signature
  Signature.byteLength signature === 64
  Signature.hexLength signature === 128

propNormalSign :: Property
propNormalSign = withTests 300 $ property $ do
  seed <- forAllWith (const "<generated test key>") (Gen.bytes (Range.singleton 32))
  message <- forAll (Gen.bytes (Range.linear 0 512))
  pair <- evalIO (SigningKey.withNormalKey seed (signPair message)) >>= evalEither
  checkVerification message pair

propExtendedSign :: Property
propExtendedSign = withTests 300 $ property $ do
  message <- forAll (Gen.bytes (Range.linear 0 512))
  pair <- evalIO (hexBytes (privateHex Fixture.extendedVector) >>= \bytes -> SigningKey.withExtendedKey bytes (signPair message)) >>= evalEither
  checkVerification message pair

checkVerification :: ByteString -> (PublicKey.PublicKey, Signature.Signature) -> PropertyT IO ()
checkVerification message (public, signature) = do
  valid <- evalIO (PublicKey.verify public message signature) >>= evalEither
  valid === True
  altered <- evalIO (PublicKey.verify public (message <> ByteString.singleton 0) signature) >>= evalEither
  altered === False

signPair :: ByteString -> SigningKey.SigningKey -> IO (Either Error (PublicKey.PublicKey, Signature.Signature))
signPair message key = do
  public <- SigningKey.publicKey key
  signature <- SigningKey.sign key message
  pure ((,) <$> public <*> signature)

withVector :: Vector -> ByteString -> (SigningKey.SigningKey -> IO (Either Error value)) -> IO (Either Error value)
withVector vector = if isExtended vector then SigningKey.withExtendedKey else SigningKey.withNormalKey

hexBytes :: Text -> IO ByteString
hexBytes text = case decodeHex text of
  Just bytes -> pure bytes
  Nothing -> assertFailure "invalid hexadecimal test fixture" >> fail "invalid fixture"

requirePure :: (Show failure) => Either failure value -> IO value
requirePure result = case result of
  Right value -> pure value
  Left failure -> assertFailure (show failure) >> fail "Ed25519 fixture operation failed"

requireRight :: (Show failure) => IO (Either failure value) -> IO value
requireRight action = action >>= requirePure

waitFor :: String -> IO value -> IO value
waitFor label action = do
  result <- timeout 10000000 action
  case result of
    Just value -> pure value
    Nothing -> assertFailure (label <> " timed out") >> fail label

alterFirst :: ByteString -> ByteString
alterFirst bytes = case ByteString.uncons bytes of
  Nothing -> ByteString.singleton 1
  Just (first, rest) -> ByteString.cons (first `xor` 1) rest

malformedHex :: [Text]
malformedHex = ["", "a", "gg", " 00", "0x00", "１２"]

-- FOREIGN IMPORTS ------------------------------------------------------------

-- Test-only retained references observe deterministic disposal without adding
-- allocation counters or pointer access to the public signing API.
foreign import ccall unsafe "cardano_ed25519_private_key_ref"
  cNativeRef :: Ptr Native.NativeKey -> IO ()

foreign import ccall unsafe "cardano_ed25519_private_key_refcount"
  cNativeRefCount :: Ptr Native.NativeKey -> IO CSize

foreign import ccall unsafe "cardano_ed25519_private_key_unref"
  cNativeUnref :: Ptr (Ptr Native.NativeKey) -> IO ()
