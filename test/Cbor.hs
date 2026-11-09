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

-- | Scalar marshaling and exact encoded-item laws. Handwritten CBOR examples
-- follow RFC 8949 major-type encodings; native transaction corpus provenance is
-- recorded separately in test/Fixtures/TRANSACTIONS.md.
module Cbor (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Encoding.Cbor as Cbor
import Cometa.Error (Error (..))
import Control.Monad (forM_, replicateM_, (>=>))
import Data.Bifunctor (bimap)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hedgehog (Property, evalEither, evalIO, forAll, property, withTests, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "CBOR foundation"
    [ testCase "floating-point widths and IEEE special values are preserved" checkFloatingPoint,
      testCase "simple values and undefined remain distinct" checkSimpleValues,
      testCase "scalar failures release readers and permit recovery" checkScalarCleanup,
      testCase "integer boundaries have independent expected encodings" checkIntegerVectors,
      testCase "out-of-range integers are rejected without truncation" checkIntegerBounds,
      testCase "byte, text and Boolean values have expected encodings" checkScalarVectors,
      testCase "nested nonminimal and indefinite items preserve exact bytes" checkRawItems,
      testCase "malformed, truncated and trailing input is rejected" checkInvalidItems,
      testCase "text decoding rejects invalid UTF-8" checkInvalidUtf8,
      testCase "scalar decoders reject a different major type" checkWrongTypes,
      testCase "arrays preserve child encodings and order" checkArrays,
      testCase "maps preserve duplicate keys and order" checkMaps,
      testCase "absent, null, empty and zero map values remain distinct" checkPresence,
      testCase "copied scalar and collection snapshots survive cleanup and GC" checkSnapshots,
      testProperty "primitive integers round trip" propInteger,
      testProperty "arbitrary bytes round trip" propBytes,
      testProperty "Unicode text round trips" propText,
      testProperty "Booleans round trip" propBool,
      testProperty "array children retain their encoded bytes" propArray,
      testProperty "ordered duplicate map entries round trip" propMap
    ]

checkIntegerVectors :: IO ()
checkIntegerVectors = mapM_ check integerVectors
  where
    check (number, expected) = do
      encoded <- requireRight (Cbor.encodeInteger number)
      Cbor.toHex encoded @?= expected
      Cbor.decodeInteger encoded >>= (@?= Right number)
      parsed <- requireRight (Cbor.fromHex expected)
      Cbor.decodeInteger parsed >>= (@?= Right number)

checkIntegerBounds :: IO ()
checkIntegerBounds = mapM_ check [negate (2 ^ (64 :: Int)) - 1, 2 ^ (64 :: Int), negate (2 ^ (256 :: Int)), 2 ^ (256 :: Int)]
  where
    check number = Cbor.encodeInteger number >>= (@?= Left (InvalidCborInteger number))

checkScalarVectors :: IO ()
checkScalarVectors = do
  empty <- requireRight (Cbor.encodeByteString ByteString.empty)
  Cbor.toHex empty @?= "40"
  bytes <- requireRight (Cbor.encodeByteString (ByteString.pack [0, 1, 2, 255]))
  Cbor.toHex bytes @?= "44000102ff"
  text <- requireRight (Cbor.encodeText "λ😀")
  Cbor.toHex text @?= "66cebbf09f9880"
  Cbor.decodeText text >>= (@?= Right "λ😀")
  embeddedNull <- requireRight (Cbor.encodeText "a\NULb")
  Cbor.toHex embeddedNull @?= "63610062"
  Cbor.decodeText embeddedNull >>= (@?= Right "a\NULb")
  blank <- requireRight (Cbor.encodeText "")
  Cbor.toHex blank @?= "60"
  false <- requireRight (Cbor.encodeBool False)
  true <- requireRight (Cbor.encodeBool True)
  map Cbor.toHex [false, true] @?= ["f4", "f5"]

checkRawItems :: IO ()
checkRawItems = mapM_ check rawItems
  where
    check encoded = do
      value <- requireRight (Cbor.fromHex encoded)
      Cbor.toHex value @?= encoded
      Cbor.fromBytes (Cbor.toBytes value) >>= (@?= Right value)

checkInvalidItems :: IO ()
checkInvalidItems = mapM_ check ["", "ff", "18", "81", "9f00", "bf0001", "5f6100ff", "a100", "0000", "00ff", "f600"]
  where
    check encoded = do
      result <- Cbor.fromHex encoded
      assertBool ("accepted malformed or trailing CBOR: " <> Text.unpack encoded) (isLeft result)

checkInvalidUtf8 :: IO ()
checkInvalidUtf8 = do
  mapM_ check ["61ff", "62c080", "63eda080", "64f4908080", "7f61c361a9ff"]
  validChunks <- requireRight (Cbor.fromHex "7f62c3a962cebbff")
  Cbor.decodeText validChunks >>= (@?= Right "éλ")
  emptyChunks <- requireRight (Cbor.fromHex "7fff")
  Cbor.decodeText emptyChunks >>= (@?= Right "")
  -- Raw items preserve accepted structure. Text validation belongs to decodeText,
  -- including when malformed text is encountered inside an array.
  nested <- requireRight (Cbor.fromHex "8161ff")
  items <- requireRight (Cbor.decodeArray nested)
  mapM_ (Cbor.decodeText >=> (@?= Left InvalidCborUtf8)) items
  where
    check encoded = do
      item <- requireRight (Cbor.fromHex encoded)
      Cbor.decodeText item >>= (@?= Left InvalidCborUtf8)

checkWrongTypes :: IO ()
checkWrongTypes = do
  nullValue <- requireRight (Cbor.fromHex "f6")
  Cbor.decodeInteger nullValue >>= assertBool "null decoded as integer" . isLeft
  Cbor.decodeByteString nullValue >>= assertBool "null decoded as bytes" . isLeft
  Cbor.decodeText nullValue >>= assertBool "null decoded as text" . isLeft
  Cbor.decodeBool nullValue >>= assertBool "null decoded as Boolean" . isLeft
  Cbor.decodeArray nullValue >>= assertBool "null decoded as array" . isLeft
  Cbor.decodeMap nullValue >>= assertBool "null decoded as map" . isLeft

checkArrays :: IO ()
checkArrays = do
  original <- requireRight (Cbor.fromHex "9f18175f41014102ffff")
  children <- requireRight (Cbor.decodeArray original)
  map Cbor.toHex children @?= ["1817", "5f41014102ff"]
  encoded <- requireRight (Cbor.encodeArray children)
  Cbor.toHex encoded @?= "8218175f41014102ff"
  empty <- requireRight (Cbor.encodeArray [])
  Cbor.toHex empty @?= "80"

checkMaps :: IO ()
checkMaps = do
  original <- requireRight (Cbor.fromHex "bf1801616118016162ff")
  entries <- requireRight (Cbor.decodeMap original)
  map (bimap Cbor.toHex Cbor.toHex) entries @?= [("1801", "6161"), ("1801", "6162")]
  encoded <- requireRight (Cbor.encodeMap entries)
  Cbor.toHex encoded @?= "a21801616118016162"

checkPresence :: IO ()
checkPresence = do
  values <- mapM (requireRight . Cbor.fromHex) ["a0", "a100f6", "a10080", "a10000"]
  entries <- mapM (requireRight . Cbor.decodeMap) values
  map (map (bimap Cbor.toHex Cbor.toHex)) entries
    @?= [[], [("00", "f6")], [("00", "80")], [("00", "00")]]
  mapM_ (\(original, pairs) -> Cbor.encodeMap pairs >>= (@?= Right original)) (zip values entries)

checkSnapshots :: IO ()
checkSnapshots = do
  original <- requireRight (Cbor.encodeText "retained λ😀")
  container <- requireRight (Cbor.encodeArray [original, original])
  children <- requireRight (Cbor.decodeArray container)
  replicateM_ 100 $ do
    _ <- requireRight (Cbor.encodeByteString (ByteString.replicate 256 42))
    _ <- requireRight (Cbor.fromHex "a2016161016162")
    pure ()
  performGC
  mapM_ (Cbor.decodeText >=> (@?= Right "retained λ😀")) children
  Cbor.decodeText original >>= (@?= Right "retained λ😀")

propInteger :: Property
propInteger = withTests 300 $ property $ do
  number <- forAll (Gen.integral (Range.linear (negate (2 ^ (64 :: Int))) (2 ^ (64 :: Int) - 1)))
  encoded <- evalIO (Cbor.encodeInteger number) >>= evalEither
  decoded <- evalIO (Cbor.decodeInteger encoded) >>= evalEither
  decoded === number

propBytes :: Property
propBytes = withTests 300 $ property $ do
  bytes <- forAll (Gen.bytes (Range.linear 0 1024))
  encoded <- evalIO (Cbor.encodeByteString bytes) >>= evalEither
  decoded <- evalIO (Cbor.decodeByteString encoded) >>= evalEither
  decoded === bytes

propText :: Property
propText = withTests 300 $ property $ do
  text <- forAll (Gen.text (Range.linear 0 256) Gen.unicode)
  encoded <- evalIO (Cbor.encodeText text) >>= evalEither
  decoded <- evalIO (Cbor.decodeText encoded) >>= evalEither
  decoded === text
  ByteString.length (Text.encodeUtf8 decoded) === ByteString.length (Text.encodeUtf8 text)

propBool :: Property
propBool = withTests 300 $ property $ do
  value <- forAll Gen.bool
  encoded <- evalIO (Cbor.encodeBool value) >>= evalEither
  decoded <- evalIO (Cbor.decodeBool encoded) >>= evalEither
  decoded === value

propArray :: Property
propArray = withTests 300 $ property $ do
  values <- forAll (Gen.list (Range.linear 0 40) (Gen.integral (Range.linear (-1000000) 1000000)))
  children <- mapM (\value -> evalIO (Cbor.encodeInteger value) >>= evalEither) values
  encoded <- evalIO (Cbor.encodeArray children) >>= evalEither
  decoded <- evalIO (Cbor.decodeArray encoded) >>= evalEither
  map Cbor.toBytes decoded === map Cbor.toBytes children

propMap :: Property
propMap = withTests 300 $ property $ do
  -- A tiny key domain deliberately produces duplicates, without sorting them.
  values <- forAll (Gen.list (Range.linear 0 40) ((,) <$> Gen.int (Range.linear 0 3) <*> Gen.bytes (Range.linear 0 32)))
  entries <- mapM encodeEntry values
  encoded <- evalIO (Cbor.encodeMap entries) >>= evalEither
  decoded <- evalIO (Cbor.decodeMap encoded) >>= evalEither
  map encodedPair decoded === map encodedPair entries
  where
    encodeEntry (key, value) = do
      first <- evalIO (Cbor.encodeInteger (toInteger key)) >>= evalEither
      second <- evalIO (Cbor.encodeByteString value) >>= evalEither
      pure (first, second)
    encodedPair (key, value) = (Cbor.toBytes key, Cbor.toBytes value)

requireRight :: (Show failure) => IO (Either failure value) -> IO value
requireRight action = do
  result <- action
  case result of
    Right value -> pure value
    Left failure -> assertFailure (show failure) >> fail "fixture operation failed"

integerVectors :: [(Integer, Text)]
integerVectors = [(0, "00"), (23, "17"), (24, "1818"), (255, "18ff"), (256, "190100"), (65535, "19ffff"), (65536, "1a00010000"), (2 ^ (32 :: Int), "1b0000000100000000"), (2 ^ (64 :: Int) - 1, "1bffffffffffffffff"), (-1, "20"), (-24, "37"), (-25, "3818"), (negate (2 ^ (64 :: Int)), "3bffffffffffffffff")]

rawItems :: [Text]
rawItems = ["1817", "5f41014102ff", "7f61616162ff", "9f00f68101ff", "bf016161016162ff", "d86400", "c249010000000000000000", "a201f60100"]

-- | Independent RFC 8949 encodings cover each width and sign boundary.
checkFloatingPoint :: IO ()
checkFloatingPoint = do
  forM_ [("f93c00", 1), ("f9c000", -2), ("f90001", 2 ** (-24)), ("f97bff", 65504), ("fa3fc00000", 1.5), ("fb3ff8000000000000", 1.5)] $ \(bytes, expected) -> do
    item <- requireRight (Cbor.fromHex bytes)
    Cbor.decodeDouble item >>= (@?= Right expected)
    Cbor.toHex item @?= bytes
  forM_ ["f98000", "fa80000000", "fb8000000000000000"] $ \bytes -> do
    item <- requireRight (Cbor.fromHex bytes)
    actual <- requireRight (Cbor.decodeDouble item)
    assertBool "negative zero sign lost" (isNegativeZero actual)
  forM_ [("f97c00", False), ("f9fc00", True), ("fa7f800000", False), ("fbfff0000000000000", True)] $ \(bytes, negative) -> do
    item <- requireRight (Cbor.fromHex bytes)
    actual <- requireRight (Cbor.decodeDouble item)
    assertBool "infinity lost" (isInfinite actual)
    (actual < 0) @?= negative
  forM_ ["f97e00", "fa7fc00000", "fb7ff8000000000000"] $ \bytes -> do
    item <- requireRight (Cbor.fromHex bytes)
    requireRight (Cbor.decodeDouble item) >>= assertBool "NaN lost" . isNaN

-- | Enumerate the byte-valued native simple domain, including nonminimal forms.
checkSimpleValues :: IO ()
checkSimpleValues = do
  forM_ [0 .. 255] $ \number -> do
    let bytes = ByteString.pack [248, number]
    item <- requireRight (Cbor.fromBytes bytes)
    Cbor.decodeSimple item >>= (@?= Right number)
    Cbor.toBytes item @?= bytes
  forM_ [0 .. 23] $ \number -> do
    item <- requireRight (Cbor.fromBytes (ByteString.singleton (224 + number)))
    Cbor.decodeSimple item >>= (@?= Right number)
  item <- requireRight Cbor.encodeUndefined
  Cbor.toHex item @?= "f7"
  Cbor.decodeSimple item >>= (@?= Right 23)
  Cbor.decodeBool item >>= assertBool "undefined decoded as Boolean" . isLeft
  values <- mapM (requireRight . Cbor.fromHex) ["f4", "f5", "f6", "f7"]
  mapM (requireRight . Cbor.decodeSimple) values >>= (@?= [20, 21, 22, 23])

checkScalarCleanup :: IO ()
checkScalarCleanup = replicateM_ 40 $ do
  wrong <- requireRight (Cbor.encodeInteger 1)
  Cbor.decodeDouble wrong >>= assertBool "integer coerced into Double" . isLeft
  Cbor.decodeSimple wrong >>= assertBool "integer decoded as simple" . isLeft
  float <- requireRight (Cbor.fromHex "f93c00")
  Cbor.decodeSimple float >>= assertBool "float decoded as simple" . isLeft
  forM_ ["f9", "f900", "fa0000", "fb00000000", "f8", "f701"] (Cbor.fromHex >=> (assertBool "invalid complete item accepted" . isLeft))
  item <- requireRight Cbor.encodeUndefined
  Cbor.decodeSimple item >>= (@?= Right 23)
