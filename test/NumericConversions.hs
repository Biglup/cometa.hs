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

-- | Independent pure numeric workflows compared with the pinned native numeric
-- constructors, getters and arithmetic. Oracle inputs exclude native abort/UB
-- domains; invalid public inputs are checked without entering those operations.
module NumericConversions (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Encoding.Integer as Integer
import Cometa.Error (Error (..))
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.UnitInterval as Unit
import Control.Monad (forM_, replicateM_, when)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word64, Word8)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CDouble (..), CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hedgehog (Property, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)
import Text.Read (readMaybe)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Numeric conversions"
    [ testCase "all radix alphabets, signs and NUL-inclusive sizes match native" textRadices,
      testCase "uppercase rendering and automatic prefixes retain native lexical rules" textRules,
      testCase "radix validation and malformed text return structured errors" invalidText,
      testCase "metadata and arbitrary Plutus integer text use public validated constructors" domainIntegers,
      testCase "explicit byte orders encode unsigned magnitude including zero" byteOrders,
      testCase "modular inverses and signed powers match native arithmetic" modular,
      testCase "invalid modular domains are total before native abort boundaries" invalidModular,
      testCase "unit interval doubles follow decimal-floor and separate-cast semantics" doubles,
      testCase "nonfinite and out-of-interval doubles are rejected" invalidDoubles,
      testCase "numeric snapshots survive repeated native cleanup and GC" lifetime,
      testProperty "arbitrary radix signed integers round trip and match native" propText,
      testProperty "generated unit interval doubles match native reduced pairs" propDouble
    ]

numbers :: [Integer]
numbers = [0, 1, -1, 61, -255, 2 ^ (64 :: Int), negate (2 ^ (257 :: Int) + 1)]

textRadices :: IO ()
textRadices = forM_ [2 .. 62] $ \base -> do
  radix <- must (Integer.mkRadix base)
  forM_ numbers $ \number -> do
    let encoded = Integer.toText radix number
    Integer.fromText radix encoded @?= Right number
    (status, native, size) <- textOracle 0 base 10 encoded 8192
    status @?= 0
    readMaybe (T.unpack native) @?= Just number
    (rendered, nativeText, nativeSize) <- textOracle 0 10 base (T.pack (show number)) 8192
    rendered @?= 0
    nativeText @?= encoded
    nativeSize @?= T.length encoded + 1
    size @?= length (show number) + 1

textRules :: IO ()
textRules = do
  forM_ [2 .. 36] $ \base -> do
    radix <- must (Integer.mkRadix base)
    forM_ numbers $ \number -> do
      upper <- must (Integer.toUpperText radix number)
      (status, native, _) <- textOracle 0 10 (negate base) (T.pack (show number)) 8192
      status @?= 0
      native @?= upper
      Integer.fromText radix upper @?= Right number
  forM_ [("0", 0), ("077", 63), ("0xFF", 255), ("-0B101", -5), (" \t-0x 1 f\n", -31), ("123\0ignored", 123)] $ \(text, expected) -> do
    Integer.fromTextAuto text @?= Right expected
    (status, native, _) <- textOracle 0 0 10 text 8192
    status @?= 0
    readMaybe (T.unpack native) @?= Just expected
  forM_ ["- 0x10", "08", "+1", "0x", "--1"] $ \text -> do
    assertBool "invalid auto-radix input" (isLeft (Integer.fromTextAuto text))
    (status, _, _) <- textOracle 0 0 10 text 8192
    assertBool "native rejected same malformed prefix" (status /= 0)
  Integer.fromText Integer.hexadecimal " - f F \n" @?= Right (-255)
  forM_ [-1, 0, 1] $ \nativeBase -> do
    (status, native, _) <- textOracle 0 10 nativeBase "-123" 8192
    status @?= 0
    native @?= Integer.toText Integer.decimal (-123)

invalidText :: IO ()
invalidText = do
  forM_ [minBound, -36, 0, 1, 63, maxBound] $ \base -> Integer.mkRadix base @?= Left (InvalidIntegerRadix base)
  forM_ ["", " ", "+1", "1.0", "0xff", "１２", "-", "\0ignored"] $ \text ->
    assertBool "invalid decimal integer text" (isLeft (Integer.fromText Integer.decimal text))
  radix <- must (Integer.mkRadix 62)
  Integer.fromText radix "Aa" @?= Right (10 * 62 + 36)
  Integer.toUpperText radix 1 @?= Left (InvalidIntegerRadix (-62))
  (status, _, _) <- textOracle 0 10 10 "123456" 1
  assertBool "short native output storage" (status /= 0)

domainIntegers :: IO ()
domainIntegers = do
  forM_ [2, 10, 16, 36, 37, 62] $ \base -> do
    radix <- must (Integer.mkRadix base)
    forM_ [negate (2 ^ (64 :: Int)), -1, 0, 2 ^ (64 :: Int) - 1] $ \number -> do
      let text = Integer.toText radix number
      metadata <- must (Metadata.integerFromText radix text)
      Metadata.view metadata @?= Metadata.IntegerValue number
      (status, native, _) <- textOracle 1 base 10 text 8192
      status @?= 0
      readMaybe (T.unpack native) @?= Just number
    forM_ numbers $ \number -> do
      let text = Integer.toText radix number
      plutus <- must (Data.integerFromText radix text)
      Data.toData plutus @?= Data.Integer number
      (status, native, _) <- textOracle 2 base 10 text 8192
      status @?= 0
      readMaybe (T.unpack native) @?= Just number
  Metadata.integerFromText Integer.decimal "18446744073709551616" @?= Left (InvalidMetadataInteger (2 ^ (64 :: Int)))
  assertBool "invalid Plutus integer text" (isLeft (Data.integerFromText Integer.decimal "1.2"))

byteOrders :: IO ()
byteOrders = do
  forM_ [Integer.LittleEndian, Integer.BigEndian] $ \order -> do
    Integer.fromBytes order B.empty @?= 0
    forM_ numbers $ \number -> do
      let bytes = Integer.toBytes order number
      Integer.fromBytes order bytes @?= abs number
      Integer.toBytes order 0 @?= B.singleton 0
      B.useAsCStringLen bytes $ \(input, count) -> allocaBytes 1024 $ \output -> allocaBytes 1024 $ \decimal -> do
        status <- cBytes (castPtr input) (fromIntegral count) (if order == Integer.LittleEndian then 1 else 0) (if number < 0 then 1 else 0) output 1024 decimal 1024
        status @?= 0
        encoded <- B.packCStringLen (castPtr output, B.length bytes)
        encoded @?= bytes
        native <- peekCString decimal
        readMaybe native @?= Just number
  Integer.toBytes Integer.BigEndian 258 @?= B.pack [1, 2]
  Integer.toBytes Integer.LittleEndian (-258) @?= B.pack [2, 1]

modular :: IO ()
modular = do
  forM_ [-17, -3, 1, 2, 3, 5, 7, 19, 2 ^ (127 :: Int) + 1] $ \value ->
    forM_ [-257, -11, -2, 2, 11, 257, 2 ^ (127 :: Int) - 1] $ \modulus ->
      when (gcd value modulus == 1) $ do
        inverse <- must (Integer.modularInverse value modulus)
        (value * inverse) `mod` abs modulus @?= 1
        native <- modularOracle False value 0 modulus
        native @?= Right inverse

  forM_ [-7, -1, 0, 1, 7, 2 ^ (128 :: Int) + 1] $ \value ->
    forM_ [-17, -1, 0, 1, 2, 33, 2 ^ (65 :: Int) + 3] $ \power ->
      forM_ [-257, -11, -1, 1, 11, 257, 2 ^ (127 :: Int) - 1] $ \modulus ->
        if power < 0 && (abs modulus <= 1 || gcd value modulus /= 1)
          then pure ()
          else do
            expected <- must (Integer.modularPower value power modulus)
            modularOracle True value power modulus >>= (@?= Right expected)
            when (power >= 0 && power <= 33 && abs modulus > 1) $ expected @?= value ^ power `mod` abs modulus

invalidModular :: IO ()
invalidModular = do
  forM_ [0, -1, 1] $ \modulus -> Integer.modularInverse 7 modulus @?= Left (InvalidModulus modulus)
  forM_ [(0, 7), (6, 9), (-12, -18)] $ \(value, modulus) -> do
    Integer.modularInverse value modulus @?= Left (NoModularInverse value modulus)
    native <- modularOracle False value 0 modulus
    assertBool "oracle guards native inverse failure" (isLeft native)
  forM_ [-1, 0, 1] $ \power -> do
    Integer.modularPower 7 power 0 @?= Left (InvalidModulus 0)
    modularOracle True 7 power 0 >>= assertBool "oracle guards zero modulus" . isLeft
  Integer.modularPower 6 (-1) 9 @?= Left (NoModularInverse 6 9)
  modularOracle True 6 (-1) 9 >>= assertBool "oracle guards negative exponent without inverse" . isLeft
  Integer.modularPower 7 0 1 @?= Right 1
  Integer.modularPower 7 1 1 @?= Right 0

doubles :: IO ()
doubles = do
  forM_ [0, -0, 1, 0.1, 0.3, 1 / 3, 0.9999999999999999, 1e-16, 1e-15, encodeFloat 1 (-1074)] $ \value -> checkDouble value
  third <- must (Unit.fromDouble (1 / 3))
  (Unit.numerator third, Unit.denominator third) @?= (333333333333333, 1000000000000000)
  tiny <- must (Unit.fromDouble 1e-16)
  (Unit.numerator tiny, Unit.denominator tiny) @?= (0, 1)
  forM_ [1.5, 2.75, 1000.125, 2 ^ (63 :: Int), 18446744073709549568] $ \number -> do
    value <- must (Rational.fromDouble number)
    alloca $ \n -> alloca $ \d -> alloca $ \approximate -> do
      status <- cUnitDouble (CDouble number) n d approximate
      status @?= 0
      nativeNumerator <- peek n
      nativeDenominator <- peek d
      CDouble nativeApproximate <- peek approximate
      (Rational.numerator value, Rational.denominator value) @?= (nativeNumerator, nativeDenominator)
      Rational.toDouble value @?= nativeApproximate
  forM_ [(0, 1), (1, 3), (2, 3), (maxBound - 1, maxBound)] $ \(n, d) -> do
    value <- must (Unit.mkUnitInterval (toInteger n) (toInteger d))
    alloca $ \output -> do
      status <- cUnitToDouble n d output
      status @?= 0
      CDouble approximate <- peek output
      Unit.toDouble value @?= approximate

invalidDoubles :: IO ()
invalidDoubles = do
  forM_ [0 / 0, 1 / 0, negate (1 / 0), -0.1, 1.0000000000000002] $ \value ->
    Unit.fromDouble value @?= Left InvalidUnitIntervalDouble
  forM_ [0 / 0, 1 / 0, negate (1 / 0), -0.1, 18446744073709551616] $ \value ->
    Rational.fromDouble value @?= Left InvalidProtocolDouble
  assertBool "fractional numerator overflow is rejected" (isLeft (Rational.fromDouble 100000.123456789))

checkDouble :: Double -> IO ()
checkDouble value = do
  interval <- must (Unit.fromDouble value)
  alloca $ \n -> alloca $ \d -> alloca $ \approximate -> do
    status <- cUnitDouble (CDouble value) n d approximate
    status @?= 0
    numerator <- peek n
    denominator <- peek d
    CDouble rounded <- peek approximate
    (Unit.numerator interval, Unit.denominator interval) @?= (numerator, denominator)
    Unit.toDouble interval @?= rounded

lifetime :: IO ()
lifetime = do
  (_, retained, _) <- textOracle 2 16 62 "-123456789abcdef0123456789abcdef" 8192
  replicateM_ 20 $ do
    textOracle 1 10 10 "invalid" 8192 >>= (\(status, _, _) -> assertBool "native parse failure" (status /= 0))
    modularOracle False 3 0 11 >>= (@?= Right 4)
    checkDouble 0.1
  performGC
  radix <- must (Integer.mkRadix 62)
  let parsed = Integer.fromText Integer.hexadecimal "-123456789abcdef0123456789abcdef"
  fmap (Integer.toText radix) parsed @?= Right retained

propText :: Property
propText = property $ do
  base <- forAll (Gen.int (Range.linear 2 62))
  value <- forAll (Gen.integral (Range.linear (negate (2 ^ (512 :: Int))) (2 ^ (512 :: Int))))
  case Integer.mkRadix base of
    Left failure -> evalIO (assertFailure (show failure))
    Right radix -> do
      let text = Integer.toText radix value
      Integer.fromText radix text === Right value
      (status, native, _) <- evalIO (textOracle 0 base 10 text 8192)
      status === 0
      readMaybe (T.unpack native) === Just value

propDouble :: Property
propDouble = property $ do
  value <- forAll (Gen.double (Range.linearFrac 0 1))
  evalIO (checkDouble value)

-- FUNCTIONS ------------------------------------------------------------------

must :: (Show e) => Either e a -> IO a
must (Right value) = pure value
must (Left failure) = assertFailure (show failure) >> fail "unreachable"

textOracle :: Int -> Int -> Int -> Text -> Int -> IO (CInt, Text, Int)
textOracle kind parseBase renderBase text capacity =
  B.useAsCStringLen (T.encodeUtf8 text) $ \(input, size) -> allocaBytes capacity $ \output -> alloca $ \required -> do
    status <- cText (fromIntegral kind) (fromIntegral parseBase) (fromIntegral renderBase) input (fromIntegral size) output (fromIntegral capacity) required
    if status /= 0
      then pure (status, "", 0)
      else do
        native <- T.pack <$> peekCString output
        count <- peek required
        pure (status, native, fromIntegral count)

modularOracle :: Bool -> Integer -> Integer -> Integer -> IO (Either CInt Integer)
modularOracle power value exponentValue modulus =
  withCString (show value) $ \input -> withCString (show exponentValue) $ \exponentInput -> withCString (show modulus) $ \modulusInput -> allocaBytes 8192 $ \output -> do
    status <- cModular (if power then 1 else 0) input exponentInput modulusInput output 8192
    if status /= 0
      then pure (Left status)
      else do
        text <- peekCString output
        case readMaybe text of
          Just result -> pure (Right result)
          Nothing -> assertFailure "malformed native modular result" >> pure (Left status)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_numeric_text"
  cText :: CInt -> CInt -> CInt -> CString -> CSize -> CString -> CSize -> Ptr CSize -> IO CInt

foreign import ccall unsafe "cometa_test_numeric_modular"
  cModular :: CInt -> CString -> CString -> CString -> CString -> CSize -> IO CInt

foreign import ccall unsafe "cometa_test_unit_double"
  cUnitDouble :: CDouble -> Ptr Word64 -> Ptr Word64 -> Ptr CDouble -> IO CInt

foreign import ccall unsafe "cometa_test_unit_to_double"
  cUnitToDouble :: Word64 -> Word64 -> Ptr CDouble -> IO CInt

foreign import ccall unsafe "cometa_test_integer_bytes"
  cBytes :: Ptr Word8 -> CSize -> Word8 -> Word8 -> Ptr Word8 -> CSize -> CString -> CSize -> IO CInt
