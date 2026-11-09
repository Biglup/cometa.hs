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

-- | Differential checks for standard Integer workflows, not a native BigInt API.
-- Provenance: native merge c5edc7c8f16b3980b6e97ef7fda80fef94adf980,
-- lib/src/common/bigint.c and lib/external/gmp/mini-gmp.c.
-- Expectations are independently composed from base Integer/Data.Bits/Numeric;
-- no native arithmetic implementation or test vectors were copied.
-- Primary Haskell source reviewed at ghc-9.6.7-release:
-- https://github.com/ghc/ghc/blob/ghc-9.6.7-release/libraries/ghc-bignum/src/GHC/Num/Integer.hs
-- https://github.com/ghc/ghc/blob/ghc-9.6.7-release/libraries/base/Data/Bits.hs
-- The former documents magnitude popCount for negatives and implements signed
-- bitwise operations and arithmetic shift-right. Use abs explicitly for counts.
module IntegerSemantics (tests) where

-- IMPORTS --------------------------------------------------------------------

import Control.Exception (ArithException (DivideByZero), evaluate, try)
import Control.Monad (forM_, replicateM_)
import Data.Bits (clearBit, complement, complementBit, popCount, setBit, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.ByteString as BS
import Data.Char (intToDigit)
import Data.Int (Int64)
import Data.List (foldl', unfoldr)
import Data.Word (Word64, Word8)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Numeric (showIntAtBase)
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)
import Text.Read (readMaybe)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Integer semantics"
    [ testCase "native division and mod use truncating quot and rem" checkDivision,
      testCase "signed bitwise operations and boundary indices match Data.Bits" checkBits,
      testCase "magnitude population count and zero-inclusive binary length" checkCounts,
      testCase "ordinary arithmetic and bounded powers agree with Integer" checkArithmetic,
      testCase "unsigned conversion truncates magnitude, byte sizes include zero" checkConversions,
      testCase "unsigned byte import and signed export preserve zero and endian magnitude" checkBytes,
      testCase "full uint64 powers agree with Integer including aliased results" checkFullWidthPowers,
      testCase "signed64 conversion preserves INT64_MIN and wraps low bits" checkSignedConversions,
      testCase "bounded decimal spans accept exact bytes and stop within their limit" checkSpans,
      testCase "zero division is rejected before native abort and partial owners are released" checkFailures,
      testCase "copied results survive repeated success, failure and collection" checkLifetime,
      testProperty "signed multiword arithmetic agrees with independent Integer operations" propArithmetic,
      testProperty "signed64 export agrees with standard Integer to Int64 conversion" propSignedConversion,
      testProperty "magnitude bytes agree with an independent Integer codec" propMagnitudeBytes
    ]

boundaries :: [Integer]
boundaries = [0, 1, -1, 7, -7, 2 ^ (63 :: Int), negate (2 ^ (63 :: Int)), 2 ^ (64 :: Int) - 1, 2 ^ (127 :: Int) + 5, negate (2 ^ (257 :: Int) + 1)]

checkDivision :: IO ()
checkDivision = do
  forM_ boundaries $ \left -> forM_ [-17, -3, -1, 1, 3, 17, 2 ^ (65 :: Int) + 1] $ \right -> do
    expectOperation 3 left right 0 [left `quot` right]
    expectOperation 4 left right 0 [left `rem` right]
    expectOperation 5 left right 0 [left `rem` right]
    let (quotient, remainder) = left `quotRem` right
    expectOperation 6 left right 0 [quotient, remainder]
    left @?= quotient * right + remainder
  -- This distinction prevents accidentally documenting native mod as Prelude.mod.
  expectOperation 5 (-7) 3 0 [-1]
  ((-7) `mod` (3 :: Integer)) @?= 2

checkBits :: IO ()
checkBits = do
  forM_ boundaries $ \left -> do
    expectOperation 10 left 0 0 [complement left]
    forM_ boundaries $ \right -> do
      expectOperation 7 left right 0 [left .&. right]
      expectOperation 8 left right 0 [left .|. right]
      expectOperation 9 left right 0 [left `xor` right]
    forM_ [0, 1, 31, 32, 63, 64, 65, 127, 128, 257, 513, 4096] $ \index -> do
      let argument = fromIntegral index
      expectOperation 11 left 0 argument [left `shiftL` index]
      expectOperation 12 left 0 argument [left `shiftR` index]
      expectOperation 13 left 0 argument [if testBit left index then 1 else 0]
      expectOperation 14 left 0 argument [setBit left index]
      expectOperation 15 left 0 argument [clearBit left index]
      expectOperation 16 left 0 argument [complementBit left index]
  expectOperation 12 (-7) 0 1 [-4]

magnitudeLength :: Integer -> Integer
magnitudeLength value = toInteger (length (showIntAtBase 2 intToDigit (abs value) ""))

checkCounts :: IO ()
checkCounts = do
  forM_ (boundaries ++ [2 ^ (n :: Int) + delta | n <- [7, 8, 31, 32, 63, 64, 255, 256], delta <- [-1, 0, 1]]) $ \value -> do
    expectOperation 17 value 0 0 [toInteger (popCount (abs value))]
    expectOperation 18 value 0 0 [magnitudeLength value]
  expectOperation 17 (-7) 0 0 [3]
  expectOperation 18 0 0 0 [1]

checkArithmetic :: IO ()
checkArithmetic = do
  forM_ boundaries $ \left -> do
    expectOperation 21 left 0 0 [abs left]
    expectOperation 22 left 0 0 [negate left]
    expectOperation 23 left 0 0 [signum left]
    expectOperation 26 left 0 0 [left + 1]
    expectOperation 27 left 0 0 [left - 1]
    forM_ boundaries $ \right -> checkBinary left right
  forM_ [-7, -1, 0, 1, 7, 2 ^ (65 :: Int)] $ \value ->
    forM_ [0, 1, 2, 3, 16] $ \power -> expectOperation 19 value 0 power [value ^ power]

checkBinary :: Integer -> Integer -> IO ()
checkBinary left right =
  forM_ [(0, left + right), (1, left - right), (2, left * right), (20, gcd left right), (24, min left right), (25, max left right)] $ \(operation, expected) ->
    expectOperation operation left right 0 [expected]

checkConversions :: IO ()
checkConversions =
  forM_ (boundaries ++ [2 ^ (128 :: Int) + 17, negate (2 ^ (128 :: Int) + 17)]) $ \value -> do
    expectOperation 28 value 0 0 [toInteger (fromInteger (abs value) :: Word64)]
    expectOperation 29 value 0 0 [(magnitudeLength value + 7) `quot` 8]

checkBytes :: IO ()
checkBytes =
  forM_ [[0], [0, 0], [1], [0, 1], [128, 255], [0, 1, 0, 255], replicate 32 255] $ \bytes ->
    forM_ [False, True] $ \little -> forM_ [False, True] $ \negative -> do
      let ordered = if little then reverse bytes else bytes
          magnitude = foldl' (\acc byte -> acc * 256 + toInteger byte) 0 ordered
          value = if negative then negate magnitude else magnitude
          count = fromInteger ((magnitudeLength magnitude + 7) `quot` 8)
          expected = magnitudeBytes little value
      (status, decimal, encoded) <- byteOracle bytes little negative count
      status @?= 0
      readMaybe decimal @?= Just value
      encoded @?= expected

magnitudeBytes :: Bool -> Integer -> BS.ByteString
magnitudeBytes little value = BS.pack (if little then digits else reverse digits)
  where
    digits = if value == 0 then [0] else unfoldr next (abs value)
    next 0 = Nothing
    next remaining = let (quotient, byte) = remaining `quotRem` 256 in Just (fromInteger byte, quotient)

propMagnitudeBytes :: Property
propMagnitudeBytes = property $ do
  bytes <- forAll (Gen.list (Range.linear 1 64) (Gen.word8 Range.constantBounded))
  little <- forAll Gen.bool
  negative <- forAll Gen.bool
  let ordered = if little then reverse bytes else bytes
      magnitude = foldl' (\acc byte -> acc * 256 + toInteger byte) 0 ordered
      value = if negative then negate magnitude else magnitude
      expected = magnitudeBytes little value
  (status, decimal, encoded) <- evalIO (byteOracle bytes little negative (BS.length expected))
  status === 0
  readMaybe decimal === Just value
  encoded === expected

checkFullWidthPowers :: IO ()
checkFullWidthPowers =
  forM_ [30, 32] $ \operation ->
    forM_ [-1, 0, 1] $ \value ->
      forM_ [0, 1, 2, 2 ^ (32 :: Int) - 1, 2 ^ (32 :: Int), 2 ^ (32 :: Int) + 1, maxBound - 1, maxBound] $ \power ->
        expectOperation operation value 0 power [value ^ power]

checkSignedConversions :: IO ()
checkSignedConversions =
  forM_ (boundaries ++ [sign * (2 ^ width + delta) | sign <- [-1, 1], width <- [63, 64, 65, 127, 128, 257 :: Int], delta <- [-1, 0, 1]]) $ \value ->
    expectOperation 31 value 0 0 [toInteger (fromInteger value :: Int64)]

checkSpans :: IO ()
checkSpans = do
  -- Each adapter input is copied to an exact allocation without an appended
  -- terminator. These span sizes are independent of its allocation length.
  forM_
    [ (BS.pack [45, 49, 50, 51], 4, -123),
      (BS.pack [49, 50, 51, 120], 3, 123),
      (BS.pack [49, 50, 51, 0], 4, 123),
      (BS.pack [49, 50, 51, 0, 120, 120], 6, 123),
      (BS.pack [49, 50, 0, 120], 4, 12),
      (BS.singleton 55, 1, 7)
    ]
    $ \(bytes, size, expected) -> do
      (status, decimal) <- spanOracle bytes size 128
      status @?= 0
      readMaybe decimal @?= Just (expected :: Integer)
  forM_ [(BS.pack [49, 50, 120], 3), (BS.singleton 55, 0), (BS.singleton 0, 1)] $ \(bytes, size) -> do
    (status, _) <- spanOracle bytes size 128
    assertBool "invalid or empty bounded decimal span" (status /= 0)
  (short, _) <- spanOracle (BS.pack [49, 50, 51]) 3 1
  assertBool "parsed span still reports short output capacity" (short /= 0)

checkFailures :: IO ()
checkFailures = do
  forM_ [3 .. 6] $ \operation -> do
    (status, _) <- rawOracle operation "7" "0" 0 128
    assertBool "test adapter rejects zero before native process abort" (status /= 0)
  division <- try (evaluate ((7 :: Integer) `quot` 0)) :: IO (Either ArithException Integer)
  division @?= Left DivideByZero
  (invalid, _) <- rawOracle 0 "invalid" "1" 0 128
  assertBool "native parse failure" (invalid /= 0)
  (short, _) <- rawOracle 0 "12345" "1" 0 1
  assertBool "short caller buffer" (short /= 0)
  (tooLarge, _) <- rawOracle 11 "1" "0" 4097 128
  assertBool "oracle prevents unbounded test allocations" (tooLarge /= 0)

checkLifetime :: IO ()
checkLifetime = do
  signed <- oracle 31 (negate (2 ^ (63 :: Int))) 0 0
  spanResult <- spanOracle (BS.pack [45, 49, 50, 51]) 4 128
  retained <- oracle 6 (negate (2 ^ (257 :: Int) + 1)) 17 0
  replicateM_ 50 $ do
    checkFailures
    expectOperation 31 (negate (2 ^ (63 :: Int))) 0 0 [toInteger (minBound :: Int64)]
    expectOperation 14 (-1) 0 257 [-1]
    expectOperation 17 (2 ^ (256 :: Int) - 1) 0 0 [256]
  performGC
  signed @?= [toInteger (minBound :: Int64)]
  spanResult @?= (0, "-123")
  retained @?= let (q, r) = negate (2 ^ (257 :: Int) + 1) `quotRem` 17 in [q, r]

propArithmetic :: Property
propArithmetic = property $ do
  left <- forAll (Gen.integral (Range.linear (negate (2 ^ (260 :: Int))) (2 ^ (260 :: Int))))
  right <- forAll (Gen.integral (Range.linear (negate (2 ^ (260 :: Int))) (2 ^ (260 :: Int))))
  forM_ [(0, left + right), (1, left - right), (2, left * right), (7, left .&. right), (8, left .|. right), (9, left `xor` right), (20, gcd left right)] $ \(operation, expected) -> do
    actual <- evalIO (oracle operation left right 0)
    actual === [expected]

propSignedConversion :: Property
propSignedConversion = property $ do
  value <- forAll (Gen.integral (Range.linear (negate (2 ^ (260 :: Int))) (2 ^ (260 :: Int))))
  actual <- evalIO (oracle 31 value 0 0)
  actual === [toInteger (fromInteger value :: Int64)]

-- FUNCTIONS ------------------------------------------------------------------

expectOperation :: Word8 -> Integer -> Integer -> Word64 -> [Integer] -> IO ()
expectOperation operation left right argument expected = do
  actual <- oracle operation left right argument
  assertEqual (show (operation, left, right, argument)) expected actual

oracle :: Word8 -> Integer -> Integer -> Word64 -> IO [Integer]
oracle operation left right argument = do
  (status, encoded) <- rawOracle operation (show left) (show right) argument 4096
  status @?= 0
  case traverse readMaybe (words encoded) of
    Just values -> pure values
    Nothing -> assertFailure ("Invalid native decimal result: " ++ encoded) >> pure []

rawOracle :: Word8 -> String -> String -> Word64 -> Int -> IO (CInt, String)
rawOracle operation left right argument capacity =
  withCString left $ \first -> withCString right $ \second -> allocaBytes capacity $ \output -> do
    status <- cOracle operation first second argument output (fromIntegral capacity)
    encoded <- if status == 0 then peekCString output else pure ""
    pure (status, encoded)

byteOracle :: [Word8] -> Bool -> Bool -> Int -> IO (CInt, String, BS.ByteString)
byteOracle bytes little negative count =
  BS.useAsCStringLen (BS.pack bytes) $ \(input, size) -> allocaBytes 256 $ \output -> allocaBytes 1024 $ \decimal -> do
    status <- cBytes (castPtr input) (fromIntegral size) (if little then 1 else 0) (if negative then 1 else 0) output 256 decimal 1024
    text <- peekCString decimal
    encoded <- if status == 0 then BS.packCStringLen (castPtr output, count) else pure BS.empty
    pure (status, text, encoded)

spanOracle :: BS.ByteString -> Int -> Int -> IO (CInt, String)
spanOracle bytes size capacity =
  BS.useAsCStringLen bytes $ \(input, actualSize) -> allocaBytes capacity $ \output -> do
    status <- cSpan input (fromIntegral actualSize) (fromIntegral size) output (fromIntegral capacity)
    decimal <- if status == 0 then peekCString output else pure ""
    pure (status, decimal)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_integer_semantics"
  cOracle :: Word8 -> CString -> CString -> Word64 -> CString -> CSize -> IO CInt

foreign import ccall unsafe "cometa_test_integer_bytes"
  cBytes :: Ptr Word8 -> CSize -> Word8 -> Word8 -> Ptr Word8 -> CSize -> CString -> CSize -> IO CInt

foreign import ccall unsafe "cometa_test_integer_span"
  cSpan :: CString -> CSize -> CSize -> CString -> CSize -> IO CInt
