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

module PlutusData (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.PlutusData as Data
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, replicateM_, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import Fixtures.PlutusData (integerVectors)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hedgehog (Gen, Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Plutus Data"
    [ testCase "pinned arbitrary integer CBOR and hashes" checkIntegerVectors,
      testCase "constructor tag transitions and maximum alternative" checkConstructors,
      testCase "bytes and bignums chunk at 64 bytes" checkChunks,
      testCase "maps retain duplicate keys and order" checkMaps,
      testCase "indefinite collections, bytes, bignums and constructors" checkIndefinite,
      testCase "original encodings retain distinct hash identity" checkIdentity,
      testCase "malformed, wrong type and trailing encodings are rejected" checkInvalid,
      testCase "typed native traversal and cache-free serialization" checkNative,
      testCase "hash lifecycle supports repeated calls and cancellation" checkLifecycle,
      testProperty "all semantic alternatives round trip" propRoundTrip,
      testProperty "native typed conversion agrees with semantic trees" propNative
    ]

checkIntegerVectors :: IO ()
checkIntegerVectors = forM_ integerVectors $ \(number, encoded, digest) -> do
  let value = Data.Integer number
  Data.encodeCbor value @?= hex encoded
  decoded <- expectRight (Data.decodeCbor (hex encoded))
  Data.toData decoded @?= value
  hashed <- Data.hash decoded >>= expectRight
  Blake2b.toHex hashed @?= Text.pack digest

checkConstructors :: IO ()
checkConstructors = forM_ [(0, "d87980"), (6, "d87f80"), (7, "d9050080"), (127, "d9057880"), (128, "d86682188080"), (maxBound, "d866821bffffffffffffffff80")] $ \(alternative, encoded) -> do
  let value = Data.Constr alternative []
  Data.encodeCbor value @?= hex encoded
  decoded <- expectRight (Data.decodeCbor (hex encoded))
  Data.toData decoded @?= value

checkChunks :: IO ()
checkChunks = do
  forM_ [0, 1, 63, 64, 65, 128, 129, 1024] $ \size -> do
    let bytes = ByteString.replicate size 171
        value = Data.Bytes bytes
    decoded <- expectRight (Data.decodeCbor (Data.encodeCbor value))
    Data.toData decoded @?= value
    when (size > 64) $ ByteString.take 1 (Data.encodeCbor value) @?= ByteString.singleton 95
  forM_ [1, -1] $ \sign -> do
    let value = Data.Integer (sign * 2 ^ (1024 :: Int))
    decoded <- expectRight (Data.decodeCbor (Data.encodeCbor value))
    Data.toData decoded @?= value
  let malformed = ByteString.pack [88, 65] <> ByteString.replicate 65 0
  assertInvalid malformed
  assertInvalid (ByteString.pack [95] <> malformed <> ByteString.singleton 255)
  assertInvalid (ByteString.pack [194] <> malformed)

checkMaps :: IO ()
checkMaps = do
  let entries = [(Data.Integer 1, Data.Bytes "a"), (Data.Integer 1, Data.Bytes "b"), (Data.Bytes "", Data.List [])]
      value = Data.Map entries
  decoded <- expectRight (Data.decodeCbor (Data.encodeCbor value))
  Data.toData decoded @?= value
  (Data.Map (reverse entries) == value) @?= False
  checkNativeValue value

checkIndefinite :: IO ()
checkIndefinite = forM_ [("bf01020103ff", Data.Map [(Data.Integer 1, Data.Integer 2), (Data.Integer 1, Data.Integer 3)]), ("9f0140ff", Data.List [Data.Integer 1, Data.Bytes ByteString.empty]), ("5f41014102ff", Data.Bytes (ByteString.pack [1, 2])), ("c25f41014100ff", Data.Integer 256), ("c35f41014100ff", Data.Integer (-257)), ("d8669f18809f01ffff", Data.Constr 128 [Data.Integer 1]), ("d8799f01ff", Data.Constr 0 [Data.Integer 1])] $ \(encoded, value) -> do
  decoded <- expectRight (Data.decodeCbor (hex encoded))
  Data.toData decoded @?= value
  Data.toCbor decoded @?= hex encoded

checkIdentity :: IO ()
checkIdentity = do
  short <- expectRight (Data.decodeCbor (hex "8101"))
  indefinite <- expectRight (Data.decodeCbor (hex "9f1801ff"))
  Data.toData short @?= Data.toData indefinite
  (short == indefinite) @?= False
  Data.toCbor indefinite @?= hex "9f1801ff"
  Data.toCbor (Data.fromData (Data.toData indefinite)) @?= hex "8101"
  shortHash <- Data.hash short >>= expectRight
  indefiniteHash <- Data.hash indefinite >>= expectRight
  (shortHash == indefiniteHash) @?= False
  expected <- Blake2b.compute 32 (hex "9f1801ff") >>= expectRight
  indefiniteHash @?= expected

checkInvalid :: IO ()
checkInvalid = forM_ ["", "00ff", "ff", "f6", "f5", "6161", "c001", "c241", "c401", "d87900", "d9057980", "d8668100", "d86683008000", "d866823080", "9f01", "bf0102", "bf01ff", "5f5f40ffff", "1c", "1b00", "d8669f008000ff", "9bffffffffffffffff", "bbffffffffffffffff"] (assertInvalid . hex)

checkNative :: IO ()
checkNative = forM_ [Data.Constr 0 [Data.Integer (negate (2 ^ (64 :: Int)) - 1), Data.List [Data.Bytes (ByteString.replicate 129 0)]], Data.Map [(Data.Integer 1, Data.Integer 2), (Data.Integer 1, Data.Integer 3)], Data.Constr maxBound []] checkNativeValue

checkLifecycle :: IO ()
checkLifecycle = do
  let datum = Data.fromData (Data.List [Data.Integer 123, Data.Bytes (ByteString.replicate 129 171)])
  expected <- Data.hash datum >>= expectRight
  replicateM_ 100 $ do
    result <- Data.hash datum >>= expectRight
    result @?= expected
  done <- newEmptyMVar
  started <- newEmptyMVar
  worker <- forkFinally (putMVar started () >> replicateM_ 1000 (Data.hash datum)) (putMVar done)
  takeMVar started
  killThread worker
  completed <- timeout 5000000 (takeMVar done)
  case completed of
    Nothing -> assertFailure "Cancelled datum hashing worker did not finish"
    Just _ -> pure ()
  actual <- Data.hash datum >>= expectRight
  actual @?= expected

propRoundTrip :: Property
propRoundTrip = property $ do
  value <- forAll genData
  decoded <- evalEither (Data.decodeCbor (Data.encodeCbor value))
  Data.toData decoded === value
  Data.toCbor decoded === Data.encodeCbor value

propNative :: Property
propNative = property $ do
  value <- forAll genData
  evalIO (checkNativeValue value)

genData :: Gen Data.PlutusData
genData =
  Gen.recursive
    Gen.choice
    [Data.Integer <$> Gen.integral (Range.linearFrom 0 (negate (2 ^ (600 :: Int))) (2 ^ (600 :: Int))), Data.Bytes <$> Gen.bytes (Range.linear 0 150)]
    [Data.Constr <$> Gen.word64 Range.constantBounded <*> Gen.list (Range.linear 0 4) genData, Data.List <$> Gen.list (Range.linear 0 4) genData, Data.Map <$> Gen.list (Range.linear 0 4) ((,) <$> genData <*> genData)]

checkNativeValue :: Data.PlutusData -> IO ()
checkNativeValue value = do
  let bytes = Data.encodeCbor value
      capacity = ByteString.length bytes * 2 + 1024
  ByteString.useAsCStringLen bytes $ \(input, size) -> allocaArray capacity $ \output -> alloca $ \outputSize -> allocaArray 8 $ \counts -> do
    status <- cOracle (castPtr input) (fromIntegral size) output (fromIntegral capacity) outputSize counts
    status @?= 0
    actualSize <- peek outputSize
    encoded <- ByteString.packCStringLen (castPtr output, fromIntegral actualSize)
    decoded <- expectRight (Data.decodeCbor encoded)
    Data.toData decoded @?= value
    actualCounts <- peekArray 8 counts
    actualCounts @?= nodeCounts value

nodeCounts :: Data.PlutusData -> [Word64]
nodeCounts value = case value of
  Data.Constr alternative fields -> add [1, 0, 0, 0, 0, alternative, 0, 0] (children fields)
  Data.Map pairs -> add [0, 1, 0, 0, 0, 0, 0, 0] (children (concatMap (\(key, item) -> [key, item]) pairs))
  Data.List values -> add [0, 0, 1, 0, 0, 0, 0, 0] (children values)
  Data.Integer number -> [0, 0, 0, 1, 0, 0, bitLength (abs number), 0]
  Data.Bytes bytes -> [0, 0, 0, 0, 1, 0, 0, fromIntegral (ByteString.length bytes)]
  where
    add = zipWith (+)
    children = foldr (add . nodeCounts) (replicate 8 0)
    bitLength 0 = 1
    bitLength number = magnitudeBits number
    magnitudeBits 0 = 0
    magnitudeBits number = 1 + magnitudeBits (number `div` 2)

assertInvalid :: ByteString -> IO ()
assertInvalid bytes = case Data.decodeCbor bytes of
  Left (InvalidPlutusDataCbor _) -> pure ()
  result -> assertFailure ("Expected InvalidPlutusDataCbor, received " <> show result)

expectRight :: (Show failure) => Either failure value -> IO value
expectRight result = case result of
  Right value -> pure value
  Left failure -> assertFailure (show failure)

hex :: String -> ByteString
hex text = ByteString.pack (go text)
  where
    go (a : b : rest) = fromIntegral (digit a * 16 + digit b) : go rest
    go _ = []
    digit character
      | character <= '9' = fromEnum character - fromEnum '0'
      | otherwise = fromEnum character - fromEnum 'a' + 10

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_plutus_data_oracle"
  cOracle :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> Ptr Word64 -> IO CUInt
