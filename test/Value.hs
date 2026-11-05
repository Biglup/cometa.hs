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

module Value (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.PolicyId as PolicyId
import qualified Cometa.Value as Value
import Control.Monad (forM_, unless)
import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import Data.List (nub, sort)
import qualified Data.Text as Text
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Gen, Property, assert, evalEither, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Assets and signed values"
    [ testCase "name byte bounds, binary data and UTF-8" checkNames,
      testCase "policy length, hex and script-hash conversion" checkPolicies,
      testCase "duplicate summation, cancellation and absence" checkNormalization,
      testCase "asset ordering and Ada versus empty native name" checkOrdering,
      testCase "unbounded signed quantities retain exact arithmetic" checkLarge,
      testCase "pinned native identifiers and safe signed arithmetic" checkNative,
      testProperty "validated name byte, hex and UTF-8 round trips" propNames,
      testProperty "normalized bundle agrees with independent association-list model" propModel,
      testProperty "addition is associative, commutative and has identity and inverses" propLaws,
      testProperty "difference and signed scaling obey arithmetic laws" propArithmetic
    ]

checkNames :: IO ()
checkNames = do
  AssetName.fromBytes ByteString.empty @?= Right AssetName.empty
  AssetName.fromHex "" @?= Right AssetName.empty
  AssetName.fromText "" @?= Right AssetName.empty
  forM_ [ByteString.replicate 32 255, ByteString.pack [0, 255, 128, 0]] $ \bytes -> do
    name <- expectRight (AssetName.fromBytes bytes)
    AssetName.toBytes name @?= bytes
    AssetName.toText name @?= Nothing
  forM_ [33, 64] $ \size -> AssetName.fromBytes (ByteString.replicate size 0) @?= Left (InvalidAssetNameLength size)
  forM_ ["a", "gg", "0x00", " 00", "１２"] $ \text -> AssetName.fromHex text @?= Left InvalidHex
  AssetName.fromHex (Text.replicate 33 "00") @?= Left (InvalidAssetNameLength 33)
  unicode <- expectRight (AssetName.fromText (Text.replicate 16 "é"))
  ByteString.length (AssetName.toBytes unicode) @?= 32
  AssetName.toText unicode @?= Just (Text.replicate 16 "é")
  AssetName.fromText (Text.replicate 17 "é") @?= Left (InvalidAssetNameLength 34)
  composed <- expectRight (AssetName.fromText "é")
  decomposed <- expectRight (AssetName.fromText "e\x0301")
  (composed == decomposed) @?= False
  binary <- expectRight (AssetName.fromText "a\0b")
  AssetName.toText binary @?= Just "a\0b"

checkPolicies :: IO ()
checkPolicies = do
  forM_ [0, 27, 29] $ \size -> PolicyId.fromBytes (ByteString.replicate size 0) @?= Left (InvalidPolicyIdLength size)
  PolicyId.fromHex "" @?= Left (InvalidPolicyIdLength 0)
  forM_ ["a", "zz", "0x00", " 00", "１２"] $ \text -> PolicyId.fromHex text @?= Left InvalidHex
  policy <- expectRight (PolicyId.fromHex (Text.replicate 28 "Ab"))
  PolicyId.toHex policy @?= Text.replicate 28 "ab"
  PolicyId.fromBytes (PolicyId.toBytes policy) @?= Right policy
  scriptHash <- expectRight (Credential.scriptHashFromBytes (PolicyId.toBytes policy))
  PolicyId.fromScriptHash scriptHash @?= policy
  PolicyId.toScriptHash policy @?= scriptHash

checkNormalization :: IO ()
checkNormalization = do
  let ada = AssetId.Ada
      value = Value.fromList [(ada, 5), (ada, -2), (ada, 0)]
  Value.toList value @?= [(ada, 3)]
  Value.singleton ada 0 @?= mempty
  Value.lovelace 0 @?= mempty
  Value.quantity ada mempty @?= 0
  Value.isZero (value <> Value.lovelace (-3)) @?= True
  Value.isNonNegative (value <> Value.lovelace (-3)) @?= True
  Value.isNonNegative (value <> Value.lovelace (-4)) @?= False
  Value.difference (Value.lovelace 2) value @?= Value.lovelace (-1)

checkOrdering :: IO ()
checkOrdering = do
  policy <- expectRight (PolicyId.fromBytes (ByteString.replicate 28 0))
  short <- expectRight (AssetName.fromBytes (ByteString.pack [255]))
  long <- expectRight (AssetName.fromBytes (ByteString.pack [0, 0]))
  let emptyToken = AssetId.Native policy AssetName.empty
      shortToken = AssetId.Native policy short
      longToken = AssetId.Native policy long
      value = Value.fromList [(shortToken, 1), (longToken, 2), (emptyToken, 3), (AssetId.Ada, 4)]
  map fst (Value.toList value) @?= [AssetId.Ada, emptyToken, longToken, shortToken]
  Value.quantity emptyToken (Value.lovelace 4) @?= 0
  Value.quantity AssetId.Ada (Value.singleton emptyToken 4) @?= 0

checkLarge :: IO ()
checkLarge = do
  let huge = 2 ^ (200 :: Int)
  forM_ [negate huge, -(2 ^ (64 :: Int)), -(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1, 2 ^ (63 :: Int), 2 ^ (64 :: Int) - 1, huge] $ \amount -> do
    Value.quantity AssetId.Ada (Value.lovelace amount) @?= amount
    Value.toList (Value.lovelace amount <> Value.lovelace amount) @?= [(AssetId.Ada, amount * 2)]
    Value.scale 0 (Value.lovelace amount) @?= mempty

-- The test-only oracle boundary checks input AND result bounds before Int64
-- conversion. No native checked arithmetic or production marshaling is claimed.
checkNative :: IO ()
checkNative = do
  forM_ [("736b7977616c6b6572", 100, 99), ("", -100, 99), (Text.replicate 32 "ff", 0, 1), ("00ff8000", 1, -1)] $ \(nameHex, leftAmount, rightAmount) -> do
    policy <- expectRight (PolicyId.fromHex (Text.replicate 28 "00"))
    name <- expectRight (AssetName.fromHex nameHex)
    let asset = AssetId.Native policy name
    forM_ [(1000000, 2000000), (0, 0), (-100, 50)] $ \(leftCoin, rightCoin) ->
      nativeAgreement policy name (Value.lovelace leftCoin <> Value.singleton asset leftAmount) (Value.lovelace rightCoin <> Value.singleton asset rightAmount)
  policy <- expectRight (PolicyId.fromHex (Text.replicate 28 "11"))
  forM_ ["30313232", "33343536", "40414242"] $ \nameHex -> do
    name <- expectRight (AssetName.fromHex nameHex)
    let asset = AssetId.Native policy name
    forM_ [toInteger (minBound :: Int64), toInteger (maxBound :: Int64)] $ \amount ->
      nativeAgreement policy name (Value.lovelace amount <> Value.singleton asset amount) mempty

nativeAgreement :: PolicyId.PolicyId -> AssetName.AssetName -> Value.Value -> Value.Value -> IO ()
nativeAgreement policy name left right = do
  let asset = AssetId.Native policy name
      summed = left <> right
      delta = Value.difference left right
      quantities value = [Value.quantity AssetId.Ada value, Value.quantity asset value]
      amounts = concatMap quantities [left, right, summed, delta]
      fits amount = amount >= toInteger (minBound :: Int64) && amount <= toInteger (maxBound :: Int64)
  unless (all fits amounts) (assertFailure "Unsafe test oracle input or result")
  case amounts of
    [lc, la, rc, ra, sc, sa, dc, da] ->
      ByteString.useAsCString (PolicyId.toBytes policy) $ \policyPtr ->
        ByteString.useAsCStringLen (AssetName.toBytes name) $ \(namePtr, nameSize) -> do
          result <- cAgreement (castPtr policyPtr) (castPtr namePtr) (fromIntegral nameSize) (fromInteger lc) (fromInteger la) (fromInteger rc) (fromInteger ra) (fromInteger sc) (fromInteger sa) (fromInteger dc) (fromInteger da)
          result @?= 1
    _ -> assertFailure "Incorrect oracle argument count"

expectRight :: (Show err) => Either err value -> IO value
expectRight = either (\err -> assertFailure (show err) >> fail "Invalid fixture") pure

propNames :: Property
propNames = property $ do
  bytes <- forAll (Gen.bytes (Range.linear 0 32))
  name <- evalEither (AssetName.fromBytes bytes)
  AssetName.toBytes name === bytes
  AssetName.fromHex (AssetName.toHex name) === Right name
  AssetName.fromHex (Text.toUpper (AssetName.toHex name)) === Right name
  case AssetName.toText name of
    Nothing -> pure ()
    Just text -> AssetName.fromText text === Right name

genEntries :: Gen [(AssetId.AssetId, Integer)]
genEntries = do
  -- A small identity space intentionally produces duplicates and cancellation.
  policyByte <- Gen.word8 (Range.linear 0 2)
  policy <- either (const Gen.discard) pure (PolicyId.fromBytes (ByteString.replicate 28 policyByte))
  Gen.list (Range.linear 0 40) $ do
    kind <- Gen.int (Range.linear 0 3)
    name <- either (const Gen.discard) pure (AssetName.fromBytes (ByteString.replicate kind 0))
    amount <- Gen.integral (Range.linear (-(2 ^ (100 :: Int))) (2 ^ (100 :: Int)))
    pure (if kind == 0 then AssetId.Ada else AssetId.Native policy name, amount)

propModel :: Property
propModel = property $ do
  entries <- forAll genEntries
  let value = Value.fromList entries
      keys = sort (nub (AssetId.Ada : map fst entries))
      expected = [(asset, total) | asset <- keys, let total = sum [amount | (key, amount) <- entries, key == asset], total /= 0]
  Value.toList value === expected
  Value.fromList (reverse entries) === value
  Value.fromList (Value.toList value) === value
  map (`Value.quantity` value) keys === [sum [amount | (key, amount) <- entries, key == asset] | asset <- keys]
  Value.isNonNegative value === all ((>= 0) . snd) expected
  Value.isZero value === null expected

propLaws :: Property
propLaws = property $ do
  a <- Value.fromList <$> forAll genEntries
  b <- Value.fromList <$> forAll genEntries
  c <- Value.fromList <$> forAll genEntries
  (a <> b) <> c === a <> (b <> c)
  a <> b === b <> a
  mempty <> a === a
  a <> mempty === a
  a <> Value.negate a === mempty
  assert (all ((/= 0) . snd) (Value.toList (a <> b)))

propArithmetic :: Property
propArithmetic = property $ do
  a <- Value.fromList <$> forAll genEntries
  b <- Value.fromList <$> forAll genEntries
  scalar <- forAll (Gen.integral (Range.linear (-100) 100))
  Value.difference a b === a <> Value.negate b
  Value.difference a a === mempty
  Value.scale scalar (a <> b) === Value.scale scalar a <> Value.scale scalar b
  Value.scale 0 a === mempty
  Value.scale 1 a === a
  Value.negate (Value.negate a) === a

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_value_agreement"
  cAgreement :: Ptr Word8 -> Ptr Word8 -> CSize -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> IO CInt
