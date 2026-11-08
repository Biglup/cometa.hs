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

module Collections (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Write as W
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.AssetName as Name
import qualified Cometa.Crypto.Blake2b as Hash
import qualified Cometa.Encoding.Collections as Collections
import Cometa.Encoding.Set (SetEncoding (..))
import Cometa.Error (Error (..))
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hedgehog (Property, evalEither, evalIO, forAll, property, tripping, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Standalone collections"
    [ testCase "asset names preserve duplicates, zero, stable byte order and signed bounds" checkNames,
      testCase "withdrawals preserve empty, zero, duplicates and full unsigned bounds" checkWithdrawals,
      testCase "variable hash lengths, duplicate retention and tag choices" checkHashes,
      testCase "indefinite containers and bytes agree with native" checkIndefinite,
      testCase "malformed, wrong type, oversized and trailing CBOR fail" checkFailures,
      testProperty "asset-name quantities round trip including signed extremes" propNames
    ]

checkNames :: IO ()
checkNames = do
  short <- expectRight (Name.fromBytes (B.singleton 255))
  long <- expectRight (Name.fromBytes (B.pack [0, 0]))
  let pairs = [(long, 3), (short, 0), (Name.empty, toInteger (minBound :: Int64)), (short, -1), (Name.empty, toInteger (maxBound :: Int64))]
      ordered = [(Name.empty, toInteger (minBound :: Int64)), (Name.empty, toInteger (maxBound :: Int64)), (short, 0), (short, -1), (long, 3)]
  encoded <- expectRight (Collections.encodeAssetNamesCbor pairs)
  Collections.decodeAssetNamesCbor encoded @?= Right ordered
  native 0 encoded >>= (@?= Just encoded)
  Collections.encodeAssetNamesCbor [] @?= Right (B.singleton 160)
  forM_ [toInteger (minBound :: Int64) - 1, toInteger (maxBound :: Int64) + 1] $ \amount ->
    Collections.encodeAssetNamesCbor [(Name.empty, amount)] @?= Left (InvalidValueQuantity amount)

checkWithdrawals :: IO ()
checkWithdrawals = do
  first <- expectRight (Reward.fromBytes (B.cons 224 (B.replicate 28 0)))
  lastAccount <- expectRight (Reward.fromBytes (B.cons 241 (B.replicate 28 0)))
  let entries = [(lastAccount, maxBound), (first, 0), (first, 1)]
      encoded = Collections.encodeWithdrawalsCbor entries
  Collections.decodeWithdrawalsCbor encoded @?= Right [(first, 0), (first, 1), (lastAccount, maxBound)]
  native 1 encoded >>= (@?= Just encoded)
  Collections.decodeWithdrawalsCbor (B.singleton 160) @?= Right []
  native 1 (Collections.encodeWithdrawalsCbor []) >>= (@?= Just (B.singleton 160))

checkHashes :: IO ()
checkHashes = do
  short <- expectRight (Hash.fromBytes (B.singleton 255))
  long <- expectRight (Hash.fromBytes (B.pack [0, 0]))
  huge <- expectRight (Hash.fromBytes (B.replicate 65 1))
  let hashes = [huge, long, short, short]
      expected = [short, short, long, huge]
      encoded = Collections.encodeHashesCbor hashes
  Collections.decodeHashesCbor encoded @?= Right expected
  native 2 encoded >>= (@?= Just encoded)
  let untagged = Collections.encodeHashesCborWith UntaggedSet hashes
  Collections.decodeHashesCbor untagged @?= Right expected
  native 2 untagged >>= (@?= Just encoded)
  Collections.encodeHashesCborWith TaggedSet hashes @?= encoded
  Collections.decodeHashesCbor (Collections.encodeHashesCbor []) @?= Right []
  native 2 (Collections.encodeHashesCbor []) >>= (@?= Just (Collections.encodeHashesCbor []))

checkIndefinite :: IO ()
checkIndefinite = do
  let names = B.pack [191, 95, 65, 255, 255, 0, 255]
      hashes = B.pack [159, 65, 255, 255]
      withdrawals = B.pack [191, 255]
  decodedNames <- expectRight (Collections.decodeAssetNamesCbor names)
  encodedNames <- expectRight (Collections.encodeAssetNamesCbor decodedNames)
  native 0 names >>= (@?= Just encodedNames)
  decodedHashes <- expectRight (Collections.decodeHashesCbor hashes)
  native 2 hashes >>= (@?= Just (Collections.encodeHashesCbor decodedHashes))
  decodedWithdrawals <- expectRight (Collections.decodeWithdrawalsCbor withdrawals)
  native 1 withdrawals >>= (@?= Just (Collections.encodeWithdrawalsCbor decodedWithdrawals))

checkFailures :: IO ()
checkFailures = do
  forM_ [B.empty, B.pack [128], B.pack [161, 0, 0], W.toStrictByteString (E.encodeMapLen 1 <> E.encodeBytes (B.replicate 33 0) <> E.encodeInt 0), W.toStrictByteString (E.encodeMapLen 1 <> E.encodeBytes B.empty <> E.encodeInteger (2 ^ (63 :: Int)))] $ \bytes -> do
    assertBool "Haskell rejects malformed names" (isLeft (Collections.decodeAssetNamesCbor bytes))
    native 0 bytes >>= (@?= Nothing)
  forM_ [B.pack [161, 64, 0], W.toStrictByteString (E.encodeMapLen 1 <> E.encodeBytes (B.cons 224 (B.replicate 28 0)) <> E.encodeInt (-1)), W.toStrictByteString (E.encodeMapLen 1 <> E.encodeBytes (B.cons 224 (B.replicate 28 0)) <> E.encodeInteger (2 ^ (64 :: Int)))] $ \bytes -> do
    assertBool "Haskell rejects malformed withdrawals" (isLeft (Collections.decodeWithdrawalsCbor bytes))
    native 1 bytes >>= (@?= Nothing)
  forM_ [B.pack [159, 95, 65, 255, 255, 255], B.pack [129, 64], B.pack [216, 1, 128], B.pack [129, 0], B.pack [161, 0, 0]] $ \bytes -> do
    assertBool "Haskell rejects malformed hashes" (isLeft (Collections.decodeHashesCbor bytes))
    native 2 bytes >>= (@?= Nothing)
  assertBool "names reject trailing bytes" (isLeft (Collections.decodeAssetNamesCbor (B.pack [160, 0])))
  assertBool "withdrawals reject trailing bytes" (isLeft (Collections.decodeWithdrawalsCbor (B.pack [160, 0])))
  assertBool "hashes reject trailing bytes" (isLeft (Collections.decodeHashesCbor (B.pack [128, 0])))

propNames :: Property
propNames = property $ do
  amounts <- forAll (Gen.list (Range.linear 0 20) (Gen.int64 Range.constantBounded))
  let pairs = [(Name.empty, toInteger amount) | amount <- amounts]
  tripping pairs Collections.encodeAssetNamesCbor (>>= Collections.decodeAssetNamesCbor)
  encoded <- evalEither (Collections.encodeAssetNamesCbor pairs)
  actual <- evalIO (native 0 encoded)
  actual === Just encoded

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\problem -> assertFailure (show problem) >> fail "unreachable") pure

native :: CInt -> ByteString -> IO (Maybe ByteString)
native kind bytes = B.useAsCStringLen bytes $ \(input, size) ->
  allocaArray 8192 $ \output -> alloca $ \written -> do
    result <- cRoundtrip kind (castPtr input) (fromIntegral size) output 8192 written
    if result /= 0
      then pure Nothing
      else do
        count <- peek written
        Just <$> B.packCStringLen (castPtr output, fromIntegral count)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_collection_roundtrip"
  cRoundtrip :: CInt -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt
