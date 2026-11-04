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

module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Callback
import qualified Cbor
import qualified Cometa
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay, yield)
import Control.Exception (AsyncException (ThreadKilled), fromException)
import Control.Monad (forever, replicateM_)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Ed25519
import qualified ErrorCode
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Ownership
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)
import qualified Transaction

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main =
  defaultMain $
    testGroup "Cometa foundation" $
      [ErrorCode.tests, Callback.tests, Ownership.tests, Cbor.tests, Transaction.tests, Ed25519.tests] ++ foundationTests

foundationTests :: [TestTree]
foundationTests =
  [ testCase "linked native version is available" $ do
      version <- Cometa.nativeVersion
      Text.null version @?= False,
    -- Independently checked with Python hashlib.blake2b(b"abc", digest_size=32).
    -- This is not claimed as a copied RFC test vector.
    testCase "BLAKE2b-256 abc known answer" $ do
      result <- Blake2b.compute 32 "abc"
      fmap Blake2b.toHex result @?= Right "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319",
    testCase "uppercase hex normalizes to lowercase" $
      fmap Blake2b.toHex (Blake2b.fromHex "00AbFF") @?= Right "00abff",
    testCase "malformed hex is rejected" $
      mapM_
        (\input -> Blake2b.fromHex input @?= Left InvalidHex)
        ["", "a", "xx", " 00", "0x00", "１２"],
    testCase "invalid digest sizes never enter C" $
      mapM_ (\size -> Blake2b.compute size "abc" >>= (@?= Left (InvalidHashLength size))) [minBound, -1, 0, 15, 65, maxBound],
    testCase "empty digest bytes return a validation error" $
      Blake2b.fromBytes ByteString.empty @?= Left EmptyHash,
    testCase "native errors preserve exact code and operation" $ do
      computed <- Blake2b.compute 32 ByteString.empty
      checkNativeFailure "blake2b.compute" Code.OutOfBoundsMemoryRead computed,
    testCase "copied bytes survive native cleanup and GC" checkCopiedBytes,
    testCase "asynchronous cancellation completes and later calls remain usable" checkCancellation,
    testProperty "bytes and hexadecimal round trips" propRoundTrip,
    testProperty "computed digest has requested length" propDigestLength
  ]

checkCopiedBytes :: IO ()
checkCopiedBytes = do
  original <- Blake2b.compute 32 "abc"
  replicateM_ 1000 $ do
    _ <- Blake2b.compute 64 "temporary native allocation"
    pure ()
  performGC
  fmap Blake2b.toHex original @?= Right "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"

checkCancellation :: IO ()
checkCancellation = replicateM_ 10 $ do
  started <- newEmptyMVar
  finished <- newEmptyMVar
  worker <-
    forkFinally
      (putMVar started () >> forever (Blake2b.compute 64 (ByteString.replicate (1024 * 1024) 42) >> yield))
      (putMVar finished)
  takeMVar started
  threadDelay 1000
  outcome <- timeout 10000000 (killThread worker >> takeMVar finished)
  case outcome of
    Just (Left exception) -> fromException exception @?= Just ThreadKilled
    Just (Right ()) -> assertFailure "Worker completed before cancellation"
    Nothing -> assertFailure "Cancellation failed to finish"
  result <- Blake2b.compute 32 "abc"
  fmap Blake2b.toHex result @?= Right "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"

checkNativeFailure :: Text.Text -> Code.ErrorCode -> Either Error value -> IO ()
checkNativeFailure operation code result = case result of
  Left (NativeError actualOperation actualCode message) -> do
    actualOperation @?= operation
    actualCode @?= code
    message @?= "Out of bounds memory read"
  Left other -> assertFailure ("Expected native error, got " <> show other)
  Right _ -> assertFailure "Expected native error, got success"

propRoundTrip :: Property
propRoundTrip = property $ do
  bytes <- forAll (Gen.bytes (Range.linear 1 512))
  digest <- evalEither (Blake2b.fromBytes bytes)
  Blake2b.toBytes digest === bytes
  Blake2b.fromHex (Blake2b.toHex digest) === Right digest
  Blake2b.fromHex (Text.toUpper (Blake2b.toHex digest)) === Right digest

propDigestLength :: Property
propDigestLength = property $ do
  size <- forAll (Gen.int (Range.linear 16 64))
  bytes <- forAll (Gen.bytes (Range.linear 1 1024))
  result <- evalIO (Blake2b.compute size bytes)
  fmap (ByteString.length . Blake2b.toBytes) result === Right size
