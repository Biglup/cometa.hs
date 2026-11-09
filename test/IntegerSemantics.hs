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
-- Provenance: pinned lib/src/common/bigint.c and lib/external/gmp/mini-gmp.c.
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
import Data.List (foldl')
import Data.Word (Word32, Word64, Word8)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt (..), CSize (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (sizeOf)
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
      testCase "unsigned byte import and nonzero export preserve endian magnitude" checkBytes,
      testCase "native zero byte-export error and exponent narrowing remain explicit" checkNativeEdges,
      testCase "zero division is rejected before native abort and partial owners are released" checkFailures,
      testCase "copied results survive repeated success, failure and collection" checkLifetime,
      testProperty "signed multiword arithmetic agrees with independent Integer operations" propArithmetic
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
  forM_ [[1], [0, 1], [128, 255], [0, 1, 0, 255], replicate 32 255] $ \bytes ->
    forM_ [False, True] $ \little -> do
      let ordered = if little then reverse bytes else bytes
          value = foldl' (\acc byte -> acc * 256 + toInteger byte) 0 ordered
          count = fromInteger ((magnitudeLength value + 7) `quot` 8)
          canonical = dropWhile (== 0) ordered
          expected = BS.pack (if little then reverse canonical else canonical)
      (status, decimal, encoded) <- byteOracle bytes little count
      status @?= 0
      readMaybe decimal @?= Just value
      encoded @?= expected

checkNativeEdges :: IO ()
checkNativeEdges = do
  -- get_bytes_size(0)=1 but mpz_export emits zero words: the native wrapper
  -- reports insufficient buffer. Preserve that known native error, do not
  -- manufacture an encoding or claim this is equivalent to a Haskell codec.
  forM_ [False, True] $ \little -> do
    (status, decimal, _) <- byteOracle [0] little 1
    status @?= 2 -- CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE, pinned cardano/error.h.
    decimal @?= "0"
  -- On LLP64 the native uint64 exponent becomes unsigned long32, so 2^32
  -- narrows to0 and native0^0=1; LP64 preserves the exponent and returns0.
  expectOperation 30 0 0 0 [if sizeOf (0 :: CULong) == 4 then 1 else 0]
  ((0 :: Integer) ^ (2 ^ (32 :: Int) :: Integer)) @?= 0

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
  retained <- oracle 6 (negate (2 ^ (257 :: Int) + 1)) 17 0
  replicateM_ 50 $ do
    checkFailures
    expectOperation 14 (-1) 0 257 [-1]
    expectOperation 17 (2 ^ (256 :: Int) - 1) 0 0 [256]
  performGC
  retained @?= let (q, r) = negate (2 ^ (257 :: Int) + 1) `quotRem` 17 in [q, r]

propArithmetic :: Property
propArithmetic = property $ do
  left <- forAll (Gen.integral (Range.linear (negate (2 ^ (260 :: Int))) (2 ^ (260 :: Int))))
  right <- forAll (Gen.integral (Range.linear (negate (2 ^ (260 :: Int))) (2 ^ (260 :: Int))))
  forM_ [(0, left + right), (1, left - right), (2, left * right), (7, left .&. right), (8, left .|. right), (9, left `xor` right), (20, gcd left right)] $ \(operation, expected) -> do
    actual <- evalIO (oracle operation left right 0)
    actual === [expected]

-- FUNCTIONS ------------------------------------------------------------------

expectOperation :: Word8 -> Integer -> Integer -> Word32 -> [Integer] -> IO ()
expectOperation operation left right argument expected = do
  actual <- oracle operation left right argument
  assertEqual (show (operation, left, right, argument)) expected actual

oracle :: Word8 -> Integer -> Integer -> Word32 -> IO [Integer]
oracle operation left right argument = do
  (status, encoded) <- rawOracle operation (show left) (show right) argument 4096
  status @?= 0
  case traverse readMaybe (words encoded) of
    Just values -> pure values
    Nothing -> assertFailure ("Invalid native decimal result: " ++ encoded) >> pure []

rawOracle :: Word8 -> String -> String -> Word32 -> Int -> IO (CInt, String)
rawOracle operation left right argument capacity =
  withCString left $ \first -> withCString right $ \second -> allocaBytes capacity $ \output -> do
    status <- cOracle operation first second argument output (fromIntegral capacity)
    encoded <- if status == 0 then peekCString output else pure ""
    pure (status, encoded)

byteOracle :: [Word8] -> Bool -> Int -> IO (CInt, String, BS.ByteString)
byteOracle bytes little count =
  BS.useAsCStringLen (BS.pack bytes) $ \(input, size) -> allocaBytes 256 $ \output -> allocaBytes 1024 $ \decimal -> do
    status <- cBytes (castPtr input) (fromIntegral size) (if little then 1 else 0) output 256 decimal 1024
    text <- peekCString decimal
    encoded <- if status == 0 then BS.packCStringLen (castPtr output, count) else pure BS.empty
    pure (status, text, encoded)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_integer_semantics"
  cOracle :: Word8 -> CString -> CString -> Word32 -> CString -> CSize -> IO CInt

foreign import ccall unsafe "cometa_test_integer_bytes"
  cBytes :: Ptr Word8 -> CSize -> Word8 -> Ptr Word8 -> CSize -> CString -> CSize -> IO CInt
