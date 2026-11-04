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

-- | Public storage, typed derivation and exception/lifetime regression scenarios.
module SoftwareKeyHandler (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PrivateKey as Private
import qualified Cometa.Crypto.Bip32.PublicKey as Bip32Public
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.Crypto.Ed25519.PublicKey as EdPublic
import qualified Cometa.Crypto.Ed25519.SigningKey as Signing
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.KeyHandler.Software as Software
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket_, fromException, throw, throwIO, try)
import Control.Monad (forM_, replicateM_, void, (>=>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Software key handlers"
    [ testCase "pinned native BIP32 storage and account public key known answer" checkNativeFixture,
      testCase "normal and extended Ed25519 encryption agree with pinned keys" checkEd25519,
      testCase "every supported entropy length derives the same typed account as BIP32" checkEntropy,
      testCase "constructor validation avoids callback and continuation" checkBounds,
      testCase "storage framing bounds prevent excessive allocation and trailing data" checkStorageBounds,
      testCase "native checksum verification rejects corrupted storage" checkChecksum,
      testCase "encrypted serialization round trip does not request a password" checkStorage,
      testCase "wrong password fails authentication after deferred loading" checkWrongPassword,
      testCase "password boundary128 and embedded NUL round trip" checkPasswords,
      testCase "invalid callback password lengths preserve structured errors" checkCallbackBounds,
      testCase "escaped and explicitly closed handles reject all operations" checkClosed,
      testCase "source key closure is independent and closed source fails" checkSource,
      testCase "continuation failure and exception close escaped handles" checkScopeFailure,
      testCase "callback exception and lazy password failure unwind safely" checkCallbackFailure,
      testCase "callback reentry returns busy without deadlock" checkReentry,
      testCase "callback failures recover on the same handle and name snapshots outlive close" checkRecovery,
      testCase "concurrent use and close are busy while callback is active" checkBusy,
      testCase "cancellation joins callback finalizer and permits later operation" checkCancellation,
      testCase "scope exit joins escaped in-flight operation" checkScopeJoin,
      testCase "independent handlers retain independent callback registrations through GC" checkIndependent
    ]

entropy :: ByteString
entropy = ByteString.pack [0 .. 31]

password :: ByteString
password = "password"

withNormal :: IO ByteString -> (Software.Handler Software.Ed25519 -> IO (Either Error value)) -> IO (Either Error value)
withNormal request action = Signing.withNormalKey (ByteString.replicate 32 1) $ \key -> Software.withSigningKey key password request action

accountPath :: IO Path.AccountPath
accountPath = Path.mkStandardAccountPath <$> requirePure (Path.mkIndex 0)

checkNativeFixture :: IO ()
checkNativeFixture = do
  bytes <- hexBytes "0a0a0a0a01010000005c97db5e09b3a4919ec75ed1126056241a1e5278731c2e0b01bea0a5f42c22db4131e0a4bbe75633677eb0e60e2ecd3520178f85c7e0d4be77a449087fe9674ee52f946b07c1b56d228c496ec0d36dd44212ba8af0f6eed1a82194dd69f479c603"
  path <- accountPath
  result <- require $ Software.withSerialized bytes (pure password) $ \case
    Software.Bip32Handler handler -> do
      Software.serialize handler >>= (@?= Right bytes)
      fmap (fmap Bip32Public.toHex) (Software.accountPublicKey handler path)
    Software.Ed25519Handler _ -> assertFailure "wrong loaded capability" >> pure (Left InvalidKeyHandlerStorage)
  result @?= "1b39889a420374e41917cf420d88a84d9b40d7eeef533ac37f323076c5f7106a15ef170481a5c4333be2b4cf498525512ac4a3427e1a0e9c9f42cfcb42ba6deb"

checkEd25519 :: IO ()
checkEd25519 = forM_ cases $ \(importKey, keyHex, publicHex) -> do
  result <- require $ importKey keyHex $ \key -> Software.withSigningKey key password (pure password) $ \handler -> fmap (fmap EdPublic.toHex) (Software.publicKey handler)
  result @?= publicHex
  where
    cases =
      [ (Signing.withNormalKeyHex, "f04462421183d227bbc0fa60799ef338169c05eed7aa6aac19bc4db20557df51", "bbdafd1393fffa82352b9792e7e8ff66fa05877a79a2486965e28049380c2cac"),
        (Signing.withExtendedKeyHex, "f04462421183d227bbc0fa60799ef338169c05eed7aa6aac19bc4db20557df51e154255decce80ae4ab8a61af6abde05e7fbc049861cc040a7afe4fb0a875899", "07473467683e6a30a13d471a68641f311a14e2b37a38ea592e5d6efc2b446bce")
      ]

checkEntropy :: IO ()
checkEntropy = do
  index <- requirePure (Path.mkIndex 2147483647)
  let path = Path.mkAccountPath index Path.cardanoCoinType index
  forM_ [16, 20, 24, 28, 32] $ \size -> do
    let bytes = ByteString.take size entropy
    expected <- require $ Private.withEntropy ByteString.empty bytes $ \root -> Private.withDerived root (Path.accountIndices path) Private.publicKey
    actual <- require $ Software.withEntropy bytes password (pure password) $ \handler -> Software.accountPublicKey handler path
    actual @?= expected

checkBounds :: IO ()
checkBounds = do
  let invoked = assertFailure "validation invoked user code" >> pure (Right ())
  forM_ [0, 1, 15, 17, 31, 33] $ \size -> Software.withEntropy (ByteString.replicate size 1) password (pure password) (const invoked) >>= (@?= Left (InvalidBip39EntropyLength size))
  forM_ [0, 129] $ \size -> Software.withEntropy entropy (ByteString.replicate size 1) (pure password) (const invoked) >>= (@?= Left (InvalidKeyHandlerPasswordLength size))

checkStorageBounds :: IO ()
checkStorageBounds = forM_ inputs $ \bytes -> Software.withSerialized bytes (throwIO (userError "callback")) (const (assertFailure "invalid storage reached scope" >> pure (Right ()))) >>= (@?= Left InvalidKeyHandlerStorage)
  where
    inputs = [ByteString.empty, ByteString.pack [10, 10, 10, 10, 1, 1, 255, 255, 255, 255], ByteString.pack [10, 10, 10, 10, 2, 1, 0, 0, 0, 76] <> ByteString.replicate 80 0, ByteString.pack [10, 10, 10, 10, 1, 2, 0, 0, 0, 92] <> ByteString.replicate 96 0, ByteString.pack [10, 10, 10, 10, 1, 0, 0, 0, 0, 91] <> ByteString.replicate 95 0]

checkChecksum :: IO ()
checkChecksum = do
  bytes <- require $ withNormal (pure password) Software.serialize
  let corrupted = ByteString.init bytes <> ByteString.singleton (ByteString.last bytes + 1)
  result <- Software.withSerialized corrupted (pure password) (const (pure (Right ())))
  case result of
    Left (NativeError _ Code.ChecksumMismatch _) -> pure ()
    other -> assertFailure (show other)
  Software.withSerialized (bytes <> "x") (pure password) (const (pure (Right ()))) >>= (@?= Left InvalidKeyHandlerStorage)

checkStorage :: IO ()
checkStorage = do
  count <- newIORef (0 :: Int)
  bytes <- require $ withNormal (modifyIORef' count (+ 1) >> pure password) $ \handler -> do
    first <- Software.serialize handler
    Software.serialize handler >>= (@?= first)
    pure first
  readIORef count >>= (@?= 0)
  Software.withSerialized
    bytes
    (modifyIORef' count (+ 1) >> pure password)
    ( \case
        Software.Ed25519Handler handler -> void (Software.publicKey handler >>= requirePure) >> pure (Right ())
        Software.Bip32Handler _ -> assertFailure "wrong mode" >> pure (Right ())
    )
    >>= (@?= Right ())
  readIORef count >>= (@?= 1)

checkWrongPassword :: IO ()
checkWrongPassword = do
  bytes <- require $ withNormal (pure password) Software.serialize
  result <- Software.withSerialized bytes (pure "wrong") $ \case
    Software.Ed25519Handler handler -> voidResult <$> Software.publicKey handler
    Software.Bip32Handler _ -> pure (Left InvalidKeyHandlerStorage)
  case result of Left (NativeError {}) -> pure (); other -> assertFailure (show other)

checkPasswords :: IO ()
checkPasswords = forM_ ["a\0b", ByteString.replicate 128 9] $ \pass -> do
  result <- Signing.withNormalKey (ByteString.replicate 32 1) $ \key -> Software.withSigningKey key pass (pure pass) (fmap voidResult . Software.publicKey)
  result @?= Right ()

checkCallbackBounds :: IO ()
checkCallbackBounds = forM_ [0, 129] $ \size -> do
  result <- withNormal (pure (ByteString.replicate size 1)) (fmap voidResult . Software.publicKey)
  result @?= Left (InvalidKeyHandlerPasswordLength size)

checkClosed :: IO ()
checkClosed = do
  escaped <- require $ withNormal (pure password) (pure . Right)
  Software.close escaped >>= (@?= Right ())
  Software.serialize escaped >>= (@?= Left KeyHandlerClosed)
  Software.publicKey escaped >>= (@?= Left KeyHandlerClosed)
  result <- withNormal (pure password) $ \handler -> do
    Software.close handler >>= (@?= Right ())
    Software.close handler >>= (@?= Right ())
    voidResult <$> Software.publicKey handler
  result @?= Left KeyHandlerClosed

checkSource :: IO ()
checkSource = do
  result <- Signing.withNormalKey (ByteString.replicate 32 1) $ \source -> Software.withSigningKey source password (pure password) $ \handler -> do
    expected <- require (Signing.publicKey source)
    Signing.close source
    Software.publicKey handler >>= (@?= Right expected)
    pure (Right ())
  result @?= Right ()
  Signing.withNormalKey (ByteString.replicate 32 1) (\source -> Signing.close source >> Software.withSigningKey source password (pure password) (const (pure (Right ())))) >>= (@?= Left SigningKeyClosed)

checkScopeFailure :: IO ()
checkScopeFailure = do
  escaped <- newEmptyMVar
  withNormal (pure password) (\handler -> putMVar escaped handler >> pure (Left InvalidKeyHandlerStorage :: Either Error ())) >>= (@?= Left InvalidKeyHandlerStorage)
  handler <- takeMVar escaped
  Software.publicKey handler >>= (@?= Left KeyHandlerClosed)
  outcome <- try $ withNormal (pure password) (\key -> putMVar escaped key >> throwIO (userError "scope")) :: IO (Either SomeException (Either Error ()))
  assertBool "scope exception propagated" (case outcome of Left _ -> True; _ -> False)
  takeMVar escaped >>= (Software.publicKey >=> (@?= Left KeyHandlerClosed))

checkCallbackFailure :: IO ()
checkCallbackFailure = forM_ [throwIO (userError "password"), pure (throw (userError "lazy password"))] $ \request -> do
  result <- try (withNormal request (fmap voidResult . Software.publicKey)) :: IO (Either SomeException (Either Error ()))
  assertBool "callback exception escaped only after native unwind" (case result of Left _ -> True; _ -> False)

checkRecovery :: IO ()
checkRecovery = do
  state <- newIORef (0 :: Int)
  let request = do
        index <- readIORef state
        modifyIORef' state (+ 1)
        case index of
          0 -> pure ByteString.empty
          1 -> throwIO (userError "callback recovery")
          _ -> pure password
  snapshot <- require $ withNormal request $ \handler -> do
    Software.publicKey handler >>= (@?= Left (InvalidKeyHandlerPasswordLength 0))
    outcome <- try (Software.publicKey handler) :: IO (Either SomeException (Either Error EdPublic.PublicKey))
    assertBool "callback exception propagated" (case outcome of Left _ -> True; _ -> False)
    void (Software.publicKey handler >>= requirePure)
    name <- Software.name handler
    Software.close handler >>= (@?= Right ())
    Software.name handler >>= (@?= Left KeyHandlerClosed)
    pure name
  snapshot @?= "Ed25519 Software Secure Key Handler"
  readIORef state >>= (@?= 3)

checkReentry :: IO ()
checkReentry = do
  slot <- newEmptyMVar
  let request = do
        handler <- takeMVar slot
        Software.publicKey handler >>= (@?= Left KeyHandlerBusy)
        Software.serialize handler >>= (@?= Left KeyHandlerBusy)
        Software.name handler >>= (@?= Left KeyHandlerBusy)
        Software.close handler >>= (@?= Left KeyHandlerBusy)
        pure password

  result <- withNormal request $ \handler -> do
    putMVar slot handler
    voidResult <$> Software.publicKey handler
  result @?= Right ()

checkBusy :: IO ()
checkBusy = do
  started <- newEmptyMVar
  release <- newEmptyMVar
  result <- withNormal (putMVar started () >> takeMVar release >> pure password) $ \handler -> do
    finished <- newEmptyMVar
    _ <- forkFinally (Software.publicKey handler) (putMVar finished)
    takeMVar started
    Software.close handler >>= (@?= Left KeyHandlerBusy)
    Software.publicKey handler >>= (@?= Left KeyHandlerBusy)
    Software.serialize handler >>= (@?= Left KeyHandlerBusy)
    Software.name handler >>= (@?= Left KeyHandlerBusy)
    putMVar release ()
    outcome <- takeMVar finished
    case outcome of Right (Right _) -> pure (); _ -> assertFailure "operation failed"
    pure (Right ())
  result @?= Right ()

checkCancellation :: IO ()
checkCancellation = do
  started <- newEmptyMVar
  finalized <- newEmptyMVar
  hold <- newEmptyMVar
  count <- newIORef (0 :: Int)
  result <- withNormal
    ( do
        n <- readIORef count
        modifyIORef' count (+ 1)
        if n == 0 then bracket_ (putMVar started ()) (putMVar finalized ()) (takeMVar hold) else pure password
    )
    $ \handler -> do
      finished <- newEmptyMVar
      thread <- forkFinally (Software.publicKey handler) (putMVar finished)
      takeMVar started
      ended <- timeout 5000000 (killThread thread >> takeMVar finished)
      case ended of
        Just (Left exception) -> fromException exception @?= Just ThreadKilled
        _ -> assertFailure "cancellation failed to join"
      takeMVar finalized
      voidResult <$> Software.publicKey handler
  result @?= Right ()

checkScopeJoin :: IO ()
checkScopeJoin = do
  started <- newEmptyMVar
  release <- newEmptyMVar
  operationFinished <- newEmptyMVar
  scopeFinished <- newEmptyMVar
  ready <- newEmptyMVar
  escaped <- newEmptyMVar
  _ <-
    forkFinally
      ( withNormal (putMVar started () >> takeMVar release >> pure password) $ \handler -> do
          putMVar escaped handler
          _ <- forkFinally (Software.publicKey handler) (putMVar operationFinished)
          takeMVar started
          putMVar ready ()
          pure (Right ())
      )
      (putMVar scopeFinished)
  handler <- takeMVar escaped
  takeMVar ready
  -- The operation keeps the pointer alive even after the user continuation exits.
  Software.close handler >>= (@?= Left KeyHandlerBusy)
  putMVar release ()
  takeMVar operationFinished >>= \case Right (Right _) -> pure (); _ -> assertFailure "operation failed"
  takeMVar scopeFinished >>= \case Right (Right ()) -> pure (); _ -> assertFailure "scope failed"
  Software.publicKey handler >>= (@?= Left KeyHandlerClosed)

checkIndependent :: IO ()
checkIndependent = replicateM_ 3 $ do
  first <- newEmptyMVar
  second <- newEmptyMVar
  done <- newEmptyMVar
  let run signal other pass = Signing.withNormalKey (ByteString.replicate 32 1) $ \source -> Software.withSigningKey source pass (putMVar signal () >> takeMVar other >> performGC >> pure pass) (fmap voidResult . Software.publicKey)
  _ <- forkFinally (run first second "first") (putMVar done)
  run second first "second" >>= (@?= Right ())
  takeMVar done >>= \case Right (Right ()) -> pure (); _ -> assertFailure "independent callback failed"

voidResult :: Either error value -> Either error ()
voidResult = void

require :: IO (Either Error value) -> IO value
require action = action >>= requirePure

requirePure :: (Show error) => Either error value -> IO value
requirePure = either (\failure -> assertFailure (show failure) >> fail "unreachable") pure

hexBytes :: Text -> IO ByteString
hexBytes text = case Hex.decodeHex text of
  Just bytes -> pure bytes
  Nothing -> assertFailure "invalid fixture hex" >> fail "fixture"
