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

module Metadata (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Metadata as Metadata
import qualified Data.Aeson as Json
import qualified Data.ByteString as BS
import Data.Scientific (scientific)
import qualified Data.Text as Text
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Gen, Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Metadata"
    [ testCase "integer and UTF-8 byte boundaries" checkBounds,
      testCase "ordered duplicate nested maps and unique labels" checkCollections,
      testCase "exact encodings retain identity until explicit normalization" checkExact,
      testCase "schema, UTF-8 and trailing input rejection" checkInvalid,
      testCase "pinned native corpus traversed through public values" checkCorpus,
      testCase "detailed JSON exact integers and invalid forms" checkJson,
      testProperty "nested metadata CBOR, JSON and native agreement" propRoundTrip,
      testProperty "left-biased metadata composition is associative" propComposition
    ]

checkBounds :: IO ()
checkBounds = do
  let bound = 2 ^ (64 :: Int)
  traverse_ (\n -> Metadata.view <$> Metadata.mkInteger n @?= Right (Metadata.IntegerValue n)) [-bound, -1, 0, bound - 1]
  traverse_ (\n -> Metadata.mkInteger n @?= Left (InvalidMetadataInteger n)) [-bound - 1, bound]
  Metadata.mkBytes (BS.replicate 65 0) @?= Left (InvalidMetadataBytesLength 65)
  Metadata.mkText (Text.replicate 17 "🙂") @?= Left (InvalidMetadataTextLength 68)
  value <- expectRight (Metadata.mkText (Text.replicate 16 "🙂"))
  Metadata.view value @?= Metadata.TextValue (Text.replicate 16 "🙂")
  nul <- expectRight (Metadata.mkText "\0")
  Metadata.view nul @?= Metadata.TextValue "\0"

checkCollections :: IO ()
checkCollections = do
  one <- expectRight (Metadata.mkInteger 1)
  two <- expectRight (Metadata.mkInteger 2)
  let pairs = [(one, two), (one, one)]
      value = Metadata.map pairs
  Metadata.view value @?= Metadata.MapValue pairs
  decoded <- expectRight (Metadata.decodeMetadatumCbor (Metadata.encodeMetadatumCbor value))
  Metadata.toMetadatum decoded @?= value
  Metadata.mkMetadata [(1, one), (1, two)] @?= Left (DuplicateMetadataLabel 1)
  metadata <- expectRight (Metadata.mkMetadata [(2, two), (1, one)])
  Metadata.toList metadata @?= [(1, one), (2, two)]
  Metadata.lookup 0 metadata @?= Nothing
  Metadata.lookup 1 (Metadata.singleton 1 two <> metadata) @?= Just two

checkExact :: IO ()
checkExact = do
  -- Indefinite map and nonminimal label/integer encodings have one semantic view.
  original <- expectRight (Metadata.decodeCbor (BS.pack [0xbf, 0x18, 0x01, 0x18, 0x02, 0xff]))
  normalized <- expectRight (Metadata.decodeCbor (BS.pack [0xa1, 0x01, 0x02]))
  Metadata.toMetadata original @?= Metadata.toMetadata normalized
  (original == normalized) @?= False
  Metadata.toCbor original @?= BS.pack [0xbf, 0x18, 0x01, 0x18, 0x02, 0xff]
  Metadata.encodeCbor (Metadata.toMetadata original) @?= Metadata.toCbor normalized
  left <- Blake2b.compute 32 (Metadata.toCbor original) >>= expectRight
  right <- Blake2b.compute 32 (Metadata.toCbor normalized) >>= expectRight
  (left == right) @?= False
  value <- expectRight (Metadata.decodeMetadatumCbor (BS.pack [0x7f, 0x61, 0x61, 0x61, 0x62, 0xff]))
  Metadata.view (Metadata.toMetadatum value) @?= Metadata.TextValue "ab"

checkInvalid :: IO ()
checkInvalid = do
  traverse_
    (assertLeft . Metadata.decodeMetadatumCbor . BS.pack)
    [ [],
      [0x01, 0x02],
      [0xf5],
      [0xf6],
      [0xc2, 0x41, 0x01],
      [0x61, 0xff],
      [0x7f, 0x61, 0xc3, 0x61, 0xa9, 0xff],
      [0x58, 0x41] ++ replicate 65 0
    ]
  deep <- expectRight (Metadata.decodeMetadatumCbor (BS.pack (replicate 130 0x81 ++ [0])))
  Metadata.encodeMetadatumCbor (Metadata.toMetadatum deep) @?= BS.pack (replicate 130 0x81 ++ [0])
  Metadata.decodeCbor (BS.pack [0xa2, 0x01, 0x00, 0x01, 0x01]) @?= Left (DuplicateMetadataLabel 1)
  traverse_ (assertLeft . Metadata.decodeCbor . BS.pack) [[0xa1, 0x20, 0x01], [0xa1, 0x61, 0x61, 0x01], [0x80]]

checkCorpus :: IO ()
checkCorpus = do
  -- Apache-2.0 cardano-c eadb95cd, lib/tests/auxiliary_data/metadatum.cpp
  -- METADATUM_CBOR, normalized from its indefinite outer and inner lists.
  n <- traverse (expectRight . Metadata.mkInteger) [1 .. 5]
  case n of
    [one, two, three, four, five] -> do
      let inner = Metadata.list [one, two, three, four, five]
          value = Metadata.list [one, two, inner, inner, five]
      encoded <- expectRight (Metadata.decodeMetadatumCbor (BS.pack [0x9f, 1, 2, 0x9f, 1, 2, 3, 4, 5, 0xff, 0x9f, 1, 2, 3, 4, 5, 0xff, 5, 0xff]))
      Metadata.toMetadatum encoded @?= value
      nativeAgreement False (Metadata.encodeMetadatumCbor value) >>= (@?= True)
      nativeAgreement True (Metadata.encodeCbor (Metadata.singleton 725 value)) >>= (@?= True)
    _ -> assertFailure "fixture assembly"

checkJson :: IO ()
checkJson = do
  traverse_ (assertLeft . Metadata.metadatumFromDetailedJson . Json.object . pure . ("int" Json..=)) [scientific 1 minBound, scientific 1 maxBound]
  traverse_
    ( \encoded -> do
        parsed <- expectRight (Json.eitherDecode encoded :: Either String Json.Value)
        assertLeft (Metadata.metadatumFromDetailedJson parsed)
    )
    ["{\"int\":1e-9223372036854775808}", "{\"int\":1e9223372036854775807}"]
  zero <- expectRight (Json.eitherDecode "{\"int\":0e-9223372036854775808}" :: Either String Json.Value)
  Metadata.metadatumFromDetailedJson zero @?= Metadata.mkInteger 0
  let maximumInteger = 2 ^ (64 :: Int) - 1
  value <- expectRight (Metadata.mkInteger maximumInteger)
  Metadata.metadatumFromDetailedJson (Metadata.metadatumToDetailedJson value) @?= Right value
  traverse_
    (assertLeft . Metadata.metadatumFromDetailedJson)
    [ Json.object ["int" Json..= (1.5 :: Double)],
      Json.object ["int" Json..= (2 ^ (64 :: Int) :: Integer)],
      Json.object ["bytes" Json..= ("gg" :: Text.Text)],
      Json.Bool True,
      Json.object ["int" Json..= (1 :: Int), "string" Json..= ("x" :: Text.Text)]
    ]
  assertLeft (Metadata.fromDetailedJson (Json.object ["01" Json..= Metadata.metadatumToDetailedJson value]))

genValue :: Gen Metadata.Metadatum
genValue =
  Gen.recursive
    Gen.choice
    [leaf]
    [ Metadata.list <$> Gen.list (Range.linear 0 4) genValue,
      Metadata.map <$> Gen.list (Range.linear 0 4) ((,) <$> genValue <*> genValue)
    ]
  where
    leaf =
      Gen.choice
        [ Gen.mapMaybe (validated . Metadata.mkInteger) (Gen.integral (Range.linear (-100000) 100000)),
          Gen.mapMaybe (validated . Metadata.mkBytes . BS.pack) (Gen.list (Range.linear 0 64) (Gen.integral (Range.linear 0 255))),
          Gen.mapMaybe (validated . Metadata.mkText . Text.pack) (Gen.list (Range.linear 0 16) (Gen.element ['a', 'é', '🙂', '\0']))
        ]
    -- Generation and shrinking both pass through the public validators.
    validated = either (const Nothing) Just

propRoundTrip :: Property
propRoundTrip = property $ do
  value <- forAll genValue
  decoded <- evalEither (Metadata.decodeMetadatumCbor (Metadata.encodeMetadatumCbor value))
  Metadata.toMetadatum decoded === value
  json <- evalEither (Metadata.metadatumFromDetailedJson (Metadata.metadatumToDetailedJson value))
  json === value
  agreement <- evalIO (nativeAgreement False (Metadata.encodeMetadatumCbor value))
  agreement === True
  let metadata = Metadata.singleton 674 value
  restored <- evalEither (Metadata.decodeCbor (Metadata.encodeCbor metadata))
  Metadata.toMetadata restored === metadata
  Metadata.fromDetailedJson (Metadata.toDetailedJson metadata) === Right metadata

propComposition :: Property
propComposition = property $ do
  a <- forAll genValue
  b <- forAll genValue
  c <- forAll genValue
  let x = Metadata.singleton 1 a
      y = Metadata.singleton 1 b
      z = Metadata.singleton 2 c
  (x <> y) <> z === x <> (y <> z)
  Metadata.lookup 1 (x <> y) === Just a
  Metadata.toList (mempty <> x) === Metadata.toList x
  Metadata.toList (x <> mempty) === Metadata.toList x

expectRight :: (Show e) => Either e a -> IO a
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure (show failure) >> fail "unreachable"

assertLeft :: (Show a) => Either e a -> IO ()
assertLeft (Left _) = pure ()
assertLeft (Right value) = assertFailure ("unexpected success: " ++ show value)

traverse_ :: (a -> IO ()) -> [a] -> IO ()
traverse_ action = foldr ((>>) . action) (pure ())

nativeAgreement :: Bool -> BS.ByteString -> IO Bool
nativeAgreement transaction bytes = BS.useAsCStringLen bytes $ \(ptr, size) ->
  (/= 0) <$> cAgreement (castPtr ptr) (fromIntegral size) (if transaction then 1 else 0)

foreign import ccall safe "cometa_test_metadata_agreement"
  cAgreement :: Ptr Word8 -> CSize -> CInt -> IO CInt
