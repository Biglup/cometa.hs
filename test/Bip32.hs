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

-- | Public BIP32 known answers, derivation laws and scoped secret lifetimes.
module Bip32 (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PrivateKey as Private
import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as EdPublic
import qualified Cometa.Crypto.Ed25519.SigningKey as Signing
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.Bip32PrivateKey as Core
import qualified Cometa.Internal.FFI.Bip32 as Native
import qualified Cometa.Internal.Hex as Hex
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket, fromException, mask_, throwIO, try)
import Control.Monad (replicateM_, void, when, (>=>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import qualified Fixtures.Bip32 as Fixture
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (poke)
import Hedgehog (Property, evalEither, evalIO, forAll, property, withTests, (===))
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
    "BIP32"
    [ testCase "native hardened and soft derivation known answers" checkKnownAnswers,
      testCase "root derivation agrees with native and independent PBKDF2 oracles" checkEntropy,
      testCase "public projection, chain code and independent hash" checkProjection,
      testCase "public and private byte/hex bounds" checkBounds,
      testCase "malformed hexadecimal never invokes a secret continuation" checkHex,
      testCase "entropy validation accepts every BIP39 size and rejects other lengths" checkEntropyBounds,
      testCase "harden sets high bit idempotently at boundary values" checkHarden,
      testCase "public derivation rejects every hardened boundary" checkHardenedPublic,
      testCase "invalid curve points and scalars fail without invalidating scope" checkInvalidMaterial,
      testCase "closed and escaped keys reject all operations" checkClosedScope,
      testCase "callback failure closes an escaped handle" checkFailure,
      testCase "exception closes an escaped handle" checkException,
      testCase "cancellation closes an escaped handle" checkCancellation,
      testCase "clone and empty-path clone survive closing their source" checkClone,
      testCase "derived and signing scopes own independent keys" checkIndependentScopes,
      testCase "public snapshots survive churn, close and GC" checkSnapshot,
      testCase "throwing derivation input leaves source operations usable" checkPathException,
      testCase "converted signing scope closes after failure, exception and cancellation" checkSigningCleanup,
      testCase "concurrent derivation and close preserve independent ownership" checkDeriveCloseRace,
      testCase "native scope consumes exactly one retained reference on every exit" checkNativeRelease,
      testProperty "public bytes and hex round trip" propPublicRoundTrip,
      testProperty "soft private derivation and public derivation commute" propCommutation,
      testProperty "private path concatenation and sequential derivation agree" propComposition
    ]

checkKnownAnswers :: IO ()
checkKnownAnswers = do
  hard <- require $ Private.withKeyHex Fixture.privateHex $ \root ->
    Private.withDerived root (map Private.harden [1852, 1815, 0]) Private.exportHex
  hard @?= Fixture.hardChildHex
  soft <- require $ Private.withKeyHex Fixture.softRootHex $ \root ->
    Private.withDerived root [1852, 1815, 0] Private.exportHex
  soft @?= Fixture.softChildHex
  public <- requirePure (Public.fromHex Fixture.softPublicHex)
  child <- require (Public.derive public [1852, 1815, 0])
  Public.toHex child @?= Fixture.softPublicChildHex
  Public.derive public [] >>= (@?= Right public)

checkEntropy :: IO ()
checkEntropy = do
  entropy <- hexBytes Fixture.entropyHex
  Private.withEntropy "some_password_@#$%^&" entropy Private.exportHex >>= (@?= Right Fixture.entropyRootHex)
  Private.withEntropy ByteString.empty (ByteString.replicate 16 0) Private.exportHex >>= (@?= Right Fixture.emptyPasswordRootHex)
  Private.withEntropy "a\0b" (ByteString.pack [0 .. 31]) Private.exportHex >>= (@?= Right Fixture.nulPasswordRootHex)

checkProjection :: IO ()
checkProjection = do
  public <- require $ Private.withKeyHex Fixture.privateHex $ \root -> do
    Private.byteLength root >>= (@?= Right 96)
    Private.hexLength root >>= (@?= Right 192)
    Private.exportHex root >>= (@?= Right Fixture.privateHex)
    _ <- require $ Private.withSigningKey root $ \key -> do
      Signing.exportHex key >>= (@?= Right (Text.take 128 Fixture.privateHex))
      signature <- require (Signing.sign key "message\0")
      edPublic <- require (Signing.publicKey key)
      EdPublic.verify edPublic "message\0" signature >>= (@?= Right True)
      pure (Right ())
    Private.publicKey root
  Public.toHex public @?= Fixture.publicHex
  Public.byteLength public @?= 64
  Public.hexLength public @?= 128
  EdPublic.toHex (Public.toEd25519 public) @?= Text.take 64 Fixture.publicHex
  Text.drop 64 (Public.toHex public) @?= Text.drop 128 Fixture.privateHex
  digest <- require (Public.hash public)
  Blake2b.toHex digest @?= Fixture.publicHashHex

checkBounds :: IO ()
checkBounds = do
  mapM_ (\size -> Public.fromBytes (ByteString.replicate size 0) @?= Left (InvalidBip32PublicKeyLength size)) [0, 1, 32, 63, 65, 96]
  mapM_ (\size -> Private.withKey (ByteString.replicate size 0) forbidden >>= (@?= Left (InvalidBip32PrivateKeyLength size))) [0, 1, 64, 95, 97, 192]
  Public.fromHex "00" @?= Left (InvalidBip32PublicKeyLength 1)
  Private.withKeyHex "00" forbidden >>= (@?= Left (InvalidBip32PrivateKeyLength 1))

checkHex :: IO ()
checkHex = do
  mapM_
    ( \input -> do
        Public.fromHex input @?= Left InvalidHex
        Private.withKeyHex input forbidden >>= (@?= Left InvalidHex)
    )
    ["", "0", "gg", " 00", "0x00", "１２"]
  Private.withKeyHex (Text.toUpper Fixture.privateHex) Private.exportHex >>= (@?= Right Fixture.privateHex)
  fmap Public.toHex (Public.fromHex (Text.toUpper Fixture.publicHex)) @?= Right Fixture.publicHex

checkEntropyBounds :: IO ()
checkEntropyBounds = do
  mapM_ (\size -> Private.withEntropy "" (ByteString.replicate size 0) forbidden >>= (@?= Left (InvalidBip39EntropyLength size))) [0, 1, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33, 64]
  mapM_ (\size -> Private.withEntropy "" (ByteString.replicate size 0) Private.byteLength >>= (@?= Right 96)) [16, 20, 24, 28, 32]

checkHarden :: IO ()
checkHarden =
  mapM_
    ( \index -> do
        let hardened = Private.harden index
        assertBool "high bit set" (hardened >= 0x80000000)
        Private.harden hardened @?= hardened
    )
    [0, 1, 0x7fffffff, 0x80000000, maxBound]

checkHardenedPublic :: IO ()
checkHardenedPublic = do
  public <- requirePure (Public.fromHex Fixture.publicHex)
  mapM_ (\index -> Public.derive public [0, index] >>= (@?= Left (HardenedPublicDerivation index))) [0x80000000, 0x80000001, maxBound]

checkInvalidMaterial :: IO ()
checkInvalidMaterial = do
  public <- requirePure (Public.fromBytes (ByteString.replicate 64 2))
  Public.derive public [0] >>= (@?= Left (NativeError "bip32.publicKey.derive" Code.GenericFailure "Generic error"))
  Private.withKey
    (ByteString.replicate 96 0)
    ( \key -> do
        Private.publicKey key >>= (@?= Left (NativeError "bip32.publicKey" Code.GenericFailure "Generic error"))
        Private.byteLength key
    )
    >>= (@?= Right 96)

checkClosedScope :: IO ()
checkClosedScope = do
  key <- require $ Private.withKeyHex Fixture.privateHex (pure . Right)
  checkClosed key

checkClosed :: Private.PrivateKey -> IO ()
checkClosed key = do
  Private.close key
  Private.close key
  Private.byteLength key >>= (@?= Left Bip32PrivateKeyClosed)
  Private.hexLength key >>= (@?= Left Bip32PrivateKeyClosed)
  Private.exportBytes key >>= (@?= Left Bip32PrivateKeyClosed)
  Private.exportHex key >>= (@?= Left Bip32PrivateKeyClosed)
  Private.publicKey key >>= (@?= Left Bip32PrivateKeyClosed)
  Private.withClone key forbidden >>= (@?= Left Bip32PrivateKeyClosed)
  Private.withDerived key [0] forbidden >>= (@?= Left Bip32PrivateKeyClosed)
  Private.withSigningKey key (const (assertFailure "closed conversion callback" >> pure (Right ()))) >>= (@?= Left Bip32PrivateKeyClosed)

checkFailure :: IO ()
checkFailure = do
  escaped <- newIORef Nothing
  Private.withKeyHex Fixture.privateHex (\key -> writeIORef escaped (Just key) >> pure (Left InvalidHex :: Either Error ())) >>= (@?= Left InvalidHex)
  readIORef escaped >>= maybe (assertFailure "missing handle") checkClosed

checkException :: IO ()
checkException = do
  escaped <- newIORef Nothing
  result <- try (Private.withKeyHex Fixture.privateHex (\key -> writeIORef escaped (Just key) >> throwIO ThreadKilled)) :: IO (Either SomeException (Either Error ()))
  case result of
    Left exception -> fromException exception @?= Just ThreadKilled
    Right _ -> assertFailure "exception swallowed"
  readIORef escaped >>= maybe (assertFailure "missing handle") checkClosed

checkCancellation :: IO ()
checkCancellation = do
  ready <- newEmptyMVar
  done <- newEmptyMVar
  blocker <- newEmptyMVar
  worker <- forkFinally (Private.withKeyHex Fixture.privateHex (\key -> putMVar ready key >> takeMVar blocker)) (putMVar done)
  key <- takeMVar ready
  outcome <- timeout 10000000 (killThread worker >> takeMVar done)
  case outcome of
    Just (Left exception) -> fromException exception @?= Just ThreadKilled
    _ -> assertFailure "cancellation did not propagate"
  checkClosed key

checkClone :: IO ()
checkClone = mapM_ check [Private.withClone, (`Private.withDerived` [])]
  where
    check clone =
      Private.withKeyHex
        Fixture.privateHex
        ( \source -> clone source $ \copy -> do
            Private.close source
            Private.exportHex copy
        )
        >>= (@?= Right Fixture.privateHex)

checkIndependentScopes :: IO ()
checkIndependentScopes = do
  Private.withKeyHex
    Fixture.privateHex
    ( \source -> Private.withDerived source [0] $ \child -> do
        Private.close source
        Private.byteLength child
    )
    >>= (@?= Right 96)
  signing <- require $ Private.withKeyHex Fixture.privateHex $ \source ->
    Private.withSigningKey source $ \key -> do
      Private.close source
      Signing.byteLength key >>= (@?= Right 64)
      pure (Right key)
  Signing.byteLength signing >>= (@?= Left SigningKeyClosed)

checkSnapshot :: IO ()
checkSnapshot = do
  public <- require (Private.withKeyHex Fixture.privateHex Private.publicKey)
  replicateM_ 100 (void (Private.withKeyHex Fixture.privateHex Private.publicKey))
  performGC
  Public.toHex public @?= Fixture.publicHex

checkPathException :: IO ()
checkPathException = do
  result <- timeout 1000000 $ Private.withKeyHex Fixture.privateHex $ \key -> do
    attempted <- try (Private.withDerived key [throwInput] forbidden) :: IO (Either SomeException (Either Error ()))
    case attempted of
      Left _ -> Private.byteLength key
      Right _ -> assertFailure "path exception swallowed" >> pure (Right 0)
  result @?= Just (Right 96)
  where
    throwInput :: Word32
    throwInput = Prelude.error "test-only path evaluation failure"

checkSigningCleanup :: IO ()
checkSigningCleanup = do
  escaped <- newIORef Nothing
  Private.withKeyHex
    Fixture.privateHex
    ( \root ->
        Private.withSigningKey root (\key -> writeIORef escaped (Just key) >> pure (Left InvalidHex :: Either Error ()))
    )
    >>= (@?= Left InvalidHex)
  checkEscapedSigning escaped
  exception <- try $ Private.withKeyHex Fixture.privateHex $ \root ->
    Private.withSigningKey root $ \key -> writeIORef escaped (Just key) >> throwIO ThreadKilled
  case (exception :: Either SomeException (Either Error ())) of
    Left cause -> fromException cause @?= Just ThreadKilled
    Right _ -> assertFailure "conversion callback exception swallowed"
  checkEscapedSigning escaped
  ready <- newEmptyMVar
  done <- newEmptyMVar
  blocker <- newEmptyMVar
  worker <-
    forkFinally
      ( Private.withKeyHex Fixture.privateHex $ \root ->
          Private.withSigningKey root $ \key -> writeIORef escaped (Just key) >> putMVar ready () >> takeMVar blocker
      )
      (putMVar done)
  takeMVar ready
  outcome <- timeout 10000000 (killThread worker >> takeMVar done)
  case outcome of
    Just (Left cause) -> fromException cause @?= Just ThreadKilled
    _ -> assertFailure "conversion callback cancellation did not propagate"
  checkEscapedSigning escaped
  where
    checkEscapedSigning escaped =
      readIORef escaped
        >>= maybe
          (assertFailure "missing signing handle")
          (Signing.byteLength >=> (@?= Left SigningKeyClosed))

checkDeriveCloseRace :: IO ()
checkDeriveCloseRace = replicateM_ 25 $ do
  result <- Private.withKeyHex Fixture.privateHex $ \root -> do
    started <- newEmptyMVar
    done <- newEmptyMVar
    _ <- forkFinally (putMVar started () >> Private.withDerived root [0, 1, 2] Private.byteLength) (putMVar done)
    takeMVar started
    Private.close root
    outcome <- timeout 10000000 (takeMVar done)
    case outcome of
      Just (Right (Right size)) -> size @?= 96
      Just (Right (Left failure)) -> failure @?= Bip32PrivateKeyClosed
      Just (Left cause) -> assertFailure (show (cause :: SomeException))
      Nothing -> assertFailure "derivation/close race did not finish"
    Private.byteLength root
  result @?= Left Bip32PrivateKeyClosed

-- Retain a second reference to prove the scoped local obligation is consumed
-- exactly once even when the native unref leaves its local slot non-NULL.
checkNativeRelease :: IO ()
checkNativeRelease = mapM_ check [False, True]
  where
    check failAction = bracket (newIORef nullPtr) release $ \owner -> do
      bytes <- hexBytes Fixture.privateHex
      result <-
        try
          ( Core.withBytesKey bytes $ \key -> do
              _ <- require $ Core.withKey key $ \pointer -> mask_ $ nativeRef pointer >> writeIORef owner pointer >> pure (Right ())
              when failAction (throwIO ThreadKilled)
          ) ::
          IO (Either SomeException (Either Core.Failure ()))
      case result of
        Left exception -> fromException exception @?= Just ThreadKilled
        Right value -> value @?= Right ()
      pointer <- readIORef owner
      nativeRefcount pointer >>= (@?= 1)
    release owner = readIORef owner >>= \pointer -> alloca $ \slot -> poke slot pointer >> Native.cUnref slot

propPublicRoundTrip :: Property
propPublicRoundTrip = withTests 300 $ property $ do
  bytes <- forAll (Gen.bytes (Range.singleton 64))
  key <- evalEither (Public.fromBytes bytes)
  otherBytes <- forAll (Gen.bytes (Range.singleton 64))
  otherKey <- evalEither (Public.fromBytes otherBytes)
  compare key otherKey === compare bytes otherBytes
  Public.toBytes key === bytes
  Public.fromHex (Public.toHex key) === Right key
  Public.fromHex (Text.toUpper (Public.toHex key)) === Right key

propCommutation :: Property
propCommutation = withTests 300 $ property $ do
  path <- forAll (Gen.list (Range.linear 0 6) (Gen.word32 (Range.linear 0 0x7fffffff)))
  pair <- evalIO $ Private.withKeyHex Fixture.softRootHex $ \key -> do
    public <- require (Private.publicKey key)
    childPublic <- Private.withDerived key path Private.publicKey
    publicChild <- Public.derive public path
    pure ((,) <$> childPublic <*> publicChild)
  (privatePublic, publicPrivate) <- evalEither pair
  privatePublic === publicPrivate

propComposition :: Property
propComposition = withTests 300 $ property $ do
  first <- forAll (Gen.list (Range.linear 0 4) (Gen.word32 Range.constantBounded))
  second <- forAll (Gen.list (Range.linear 0 4) (Gen.word32 Range.constantBounded))
  pair <- evalIO $ Private.withKeyHex Fixture.privateHex $ \key -> do
    direct <- Private.withDerived key (first ++ second) Private.exportHex
    sequential <- Private.withDerived key first $ \child -> Private.withDerived child second Private.exportHex
    pure ((,) <$> direct <*> sequential)
  (direct, sequential) <- evalEither pair
  -- Never render either secret in property diagnostics.
  (direct == sequential) === True

forbidden :: Private.PrivateKey -> IO (Either Error ())
forbidden _ = assertFailure "invalid input invoked continuation" >> pure (Right ())

require :: (Show err) => IO (Either err value) -> IO value
require action = action >>= requirePure

requirePure :: (Show err) => Either err value -> IO value
requirePure result = case result of
  Left failure -> assertFailure (show failure) >> fail "unexpected failure"
  Right value -> pure value

hexBytes :: Text -> IO ByteString
hexBytes input = maybe (fail "invalid test hex") pure (Hex.decodeHex input)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cardano_bip32_private_key_ref"
  nativeRef :: Ptr Native.NativeKey -> IO ()

foreign import ccall unsafe "cardano_bip32_private_key_refcount"
  nativeRefcount :: Ptr Native.NativeKey -> IO CSize
