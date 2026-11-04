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

module Bip39 (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PrivateKey as PrivateKey
import qualified Cometa.Crypto.Bip39 as Bip39
import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.Bip39 as Native
import Cometa.Internal.Hex (decodeHex)
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, yield)
import Control.Exception (AsyncException (ThreadKilled), evaluate, fromException)
import Control.Monad (forM_, replicateM)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Data.Word (Word8)
import Fixtures.Bip39 (vectors)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray, pokeArray)
import Hedgehog (Property, evalEither, forAll, property, withTests, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "BIP39"
    [ testCase "native corpus and independent 160/224-bit checksum vectors" checkVectors,
      testCase "entropy lengths are validated" $ forM_ [0, 1, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33] $ \n -> do
        let result = Bip39.fromEntropy (ByteString.replicate n 0)
        expectError (InvalidBip39EntropyLength n) result,
      testCase "word counts are validated" $ forM_ [0, 1, 11, 13, 14, 16, 17, 19, 20, 22, 23, 25] $ \n ->
        expectError (InvalidBip39WordCount n) (Bip39.fromWords (replicate n "abandon")),
      testCase "unknown dictionary word" $ expectError UnknownBip39Word (Bip39.fromWords ("notaword" : replicate 11 "abandon")),
      testCase "checksum failure" $ expectError InvalidBip39Checksum (Bip39.fromWords (replicate 12 "abandon")),
      testCase "NUL upper case non-ASCII and embedded whitespace rejected" $ forM_ ["abandon\0", "Abandon", "ábaco", "abandon about", "", "\xfffd"] $ \word ->
        expectError (InvalidBip39Word 1) (Bip39.fromWords (word : replicate 11 "abandon")),
      testCase "invalid word reports one-based position without secret" $
        expectError (InvalidBip39Word 12) (Bip39.fromWords (replicate 11 "abandon" ++ ["ABOUT"])),
      testCase "Unicode whitespace normalizes to single spaces" $ do
        let result = Bip39.fromText (" \t" <> Text.intercalate "\x2003\n" (replicate 11 "abandon" ++ ["about"]) <> "\r ")
        fmap Bip39.exportText result @?= Right zeroPhrase,
      testCase "public native wipe clears only the requested buffer extent" checkWipe,
      testCase "snapshots survive GC and repeated failure" checkSnapshots,
      testCase "concurrent evaluation and shared thunk" checkConcurrent,
      testCase "cancellation smoke leaves later conversions usable" checkCancellation,
      testCase "exported entropy feeds scoped BIP32 root" checkRoot,
      testProperty "entropy and mnemonic round trips for every standard size" propRoundTrip
    ]

zeroPhrase :: Text.Text
zeroPhrase = Text.unwords (replicate 11 "abandon" ++ ["about"])

expectError :: Error -> Either Error a -> IO ()
expectError expected result = case result of
  Left err -> err @?= expected
  Right _ -> assertFailure "Expected validation failure"

checkVectors :: IO ()
checkVectors = forM_ vectors $ \(hex, phrase) -> case decodeHex hex of
  Nothing -> assertFailure "Malformed test entropy"
  Just entropy -> do
    let generated = Bip39.fromEntropy entropy
    fmap Bip39.exportText generated @?= Right phrase
    let parsed = Bip39.fromText phrase
    case parsed of
      Left err -> assertFailure (show err)
      Right mnemonic -> do
        Bip39.wordCount mnemonic @?= length (Text.words phrase)
        Bip39.exportEntropy mnemonic @?= Right entropy

checkSnapshots :: IO ()
checkSnapshots = do
  original <- evaluate (Bip39.fromText zeroPhrase)
  forM_ [1 .. 100] $ \n -> do
    checkRoundTrip n
    expectError UnknownBip39Word (Bip39.fromWords (Text.replicate n "x" : replicate 11 "abandon"))
  performGC
  fmap Bip39.exportText original @?= Right zeroPhrase

-- Distinct inputs resist loop floating; GC runs between conversion and export.
checkRoundTrip :: Int -> IO ()
checkRoundTrip n = do
  let entropy = ByteString.pack (take (16 + 4 * (n `mod` 5)) (cycle [fromIntegral n, 73, 255]))
  case Bip39.fromEntropy entropy of
    Left err -> assertFailure (show err)
    Right mnemonic -> do
      _ <- evaluate (Bip39.wordCount mnemonic)
      performGC
      Bip39.exportEntropy mnemonic @?= Right entropy

checkConcurrent :: IO ()
checkConcurrent = do
  let shared = Bip39.fromEntropy (ByteString.replicate 32 0)
  slots <- replicateM 8 newEmptyMVar
  forM_ (zip [1 ..] slots) $ \(worker, slot) -> do
    _ <-
      forkFinally
        ( do
            fmap Bip39.wordCount shared @?= Right 24
            forM_ [1 .. 10] (checkRoundTrip . (+ (worker * 10)))
        )
        (putMVar slot)
    pure ()
  result <- timeout 10000000 (mapM takeMVar slots)
  case result of
    Nothing -> assertFailure "Concurrent evaluation timed out"
    Just results -> mapM_ (either (assertFailure . show) pure) results

-- Scheduling smoke test: it cannot ensure delivery during a tiny native call.
checkCancellation :: IO ()
checkCancellation = do
  started <- newEmptyMVar
  done <- newEmptyMVar
  worker <-
    forkFinally
      (putMVar started () >> mapM_ (\n -> checkRoundTrip n >> yield) [0 ..])
      (putMVar done)
  takeMVar started
  result <- timeout 10000000 (killThread worker >> takeMVar done)
  case result of
    Just (Left err) -> fromException err @?= Just ThreadKilled
    _ -> assertFailure "Cancellation failed"
  let parsed = Bip39.fromText zeroPhrase
  fmap Bip39.wordCount parsed @?= Right 12
  checkRoundTrip 127

checkRoot :: IO ()
checkRoot = do
  let parsed = Bip39.fromText zeroPhrase
  case parsed of
    Left err -> assertFailure (show err)
    Right mnemonic -> do
      let entropy = Bip39.exportEntropy mnemonic
      case entropy of
        Left err -> assertFailure (show err)
        Right bytes -> do
          result <- PrivateKey.withEntropy ByteString.empty bytes (\_ -> pure (Right ()))
          result @?= Right ()

propRoundTrip :: Property
propRoundTrip = withTests 300 $ property $ do
  size <- forAll (Gen.element [16, 20, 24, 28, 32])
  entropy <- forAll (Gen.bytes (Range.singleton size))
  mnemonic <- evalEither (Bip39.fromEntropy entropy)
  Bip39.wordCount mnemonic === size * 3 `div` 4
  let restored = Bip39.exportEntropy mnemonic
  restored === Right entropy
  parsed <- evalEither (Bip39.fromText (Bip39.exportText mnemonic))
  Bip39.exportText parsed === Bip39.exportText mnemonic

checkWipe :: IO ()
checkWipe = allocaBytes 40 $ \buffer -> do
  pokeArray buffer (replicate 40 (255 :: Word8))
  Native.cClear buffer 32
  bytes <- peekArray 40 buffer
  bytes @?= replicate 32 0 ++ replicate 8 255
