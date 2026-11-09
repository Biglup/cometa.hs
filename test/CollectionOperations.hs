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

-- | Native raw collection operations checked against ordinary maps and lists.
-- These are original bounded generators, not normalized Value tests. The C
-- getter snapshots retain stored zero entries, duplicate names and empty policies.
-- Provenance: containers v0.6.7 Data.Map.Strict.Internal (BSD-3-Clause),
-- cardano-api c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a Value/Internal.hs
-- (Apache-2.0), and cardano-c a19dbc9185112ab2d7126c9c28058388a37bdccc
-- assets/{asset_id_map,asset_name_map,multi_asset}.c and common/withdrawal_map.c
-- (Apache-2.0). Upstream implementations are reviewed, not copied into this file.
module CollectionOperations (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Read as R
import qualified Codec.CBOR.Write as W
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as Name
import qualified Cometa.Encoding.Collections as Collections
import Cometa.Error (Error)
import qualified Cometa.PolicyId as Policy
import Control.Monad (forM_, replicateM, replicateM_)
import Data.Bifunctor (first, second)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hedgehog (Gen, Property, classify, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- TYPES ----------------------------------------------------------------------

type Pairs = [(ByteString, Integer)]

data Snapshot = Flat Pairs [Integer] | Nested [(ByteString, Snapshot)] deriving (Eq, Show)

data Reply = Reply Snapshot Snapshot Snapshot (Maybe Bool) deriving (Eq, Show)

data Fixture = Fixture
  { names :: [Name.AssetName],
    identifiers :: [Asset.AssetId],
    policies :: [Policy.PolicyId],
    accounts :: [Reward.RewardAddress]
  }

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Raw collection operations"
    [ testCase "explicit zeros, duplicate first-match updates and clone independence" checkBoundaries,
      testCase "malformed requests release native owners and later calls recover" checkFailures,
      testProperty "asset-id maps correspond to zero-preserving host maps" propIds,
      testProperty "decoded asset-name maps retain duplicates and replace only the first match" propNames,
      testProperty "withdrawal insertion appends duplicate accounts rather than replacing" propWithdrawals,
      testProperty "nested raw multiasset maps retain empty policies and scoped arithmetic" propMulti
    ]

fixture :: Either Error Fixture
fixture = do
  short <- Name.fromBytes (B.singleton 255)
  long <- Name.fromBytes (B.pack [0, 0])
  zero <- Name.fromBytes (B.singleton 0)
  firstPolicy <- Policy.fromBytes (B.replicate 28 0)
  secondPolicy <- Policy.fromBytes (B.replicate 28 1)
  thirdPolicy <- Policy.fromBytes (B.replicate 28 2)
  addresses <- traverse Reward.fromBytes [B.cons 224 (B.replicate 28 0), B.cons 225 (B.replicate 28 1), B.cons 240 (B.replicate 28 2)]
  pure (Fixture [Name.empty, short, long, zero] [Asset.Ada, Asset.Native firstPolicy Name.empty, Asset.Native firstPolicy short, Asset.Native firstPolicy long, Asset.Native secondPolicy zero] [firstPolicy, secondPolicy, thirdPolicy] addresses)

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "Invalid fixture") pure

ordered :: Pairs -> Pairs
ordered = sortOn (\(key, _) -> (B.length key, key))

-- Native get returns the FIRST stored matching entry, including explicit zero.
flat :: Pairs -> Snapshot
flat pairs = Flat pairs [amount | (key, _) <- pairs, Just amount <- [lookup key pairs]]

mapBytes :: Pairs -> ByteString
mapBytes pairs = W.toStrictByteString (E.encodeMapLen (fromIntegral (length pairs)) <> foldMap (\(key, amount) -> E.encodeBytes key <> E.encodeInteger amount) pairs)

idBytes :: Asset.AssetId -> Either Error ByteString
idBytes Asset.Ada = Right B.empty
idBytes value = Asset.toBytes value

idPairs :: [(Asset.AssetId, Integer)] -> Either Error Pairs
idPairs = traverse (\(asset, amount) -> (,) <$> idBytes asset <*> pure amount)

-- Ordering for native indexed access is byte length then bytes, not Ord AssetId.
idState :: [(Asset.AssetId, Integer)] -> Either Error Pairs
idState values = ordered <$> idPairs (Map.toList (Map.fromList values))

namePairs :: [(Name.AssetName, Integer)] -> Pairs
namePairs = map (first Name.toBytes)

-- A first-occurrence association-list replacement keeps all later duplicates.
replaceFirst :: ByteString -> Integer -> Pairs -> Pairs
replaceFirst key amount values = case break ((== key) . fst) values of
  (before, []) -> ordered (before <> [(key, amount)])
  (before, _ : after) -> before <> [(key, amount)] <> after

updates :: Pairs -> Pairs -> Pairs
updates = foldl' (\values (key, amount) -> replaceFirst key amount values)

-- Copying lhs through insert makes its final occurrence win. Each rhs entry
-- then contributes once; arithmetic removes zero results but ordinary inserts do
-- not. Integer expectations cannot overflow the bounded native input ranges.
arithmetic :: Integer -> Pairs -> Pairs -> Pairs
arithmetic sign left right = ordered (Map.toList (Map.filter (/= 0) (Map.unionWith (+) (Map.fromList left) (Map.fromListWith (+) [(key, sign * amount) | (key, amount) <- right]))))

flatExpected :: Int -> Int -> Pairs -> Pairs -> Reply
flatExpected kind operation left right = Reply (flat result) (flat left) (flat right) equal
  where
    result = case operation of
      1 | kind == 2 -> ordered (left <> right)
      1 -> updates left right
      2 -> arithmetic 1 left right
      3 -> arithmetic (-1) left right
      _ -> left
    equal = if kind == 2 then Nothing else Just (result == right)

signedEntries :: (Show key) => [key] -> Gen [(key, Integer)]
signedEntries keys = Gen.list (Range.linear 0 12) ((,) <$> Gen.element keys <*> amount)
  where
    amount = Gen.frequency [(2, pure 0), (8, Gen.integral (Range.linear (-1000) 1000))]

propIds :: Property
propIds = property $ do
  f <- evalEither fixture
  left <- forAll (signedEntries (identifiers f))
  right <- forAll (signedEntries (identifiers f))
  rawLeft <- evalEither (idPairs left)
  rawRight <- evalEither (idPairs right)
  storedLeft <- evalEither (idState left)
  storedRight <- evalEither (idState right)
  classify "stored zero" (any ((== 0) . snd) storedLeft)
  classify "replacement" (length left > Map.size (Map.fromList left))
  forM_ [0 .. 3] $ \operation -> do
    actual <- evalIO (native 0 operation (mapBytes rawLeft) (mapBytes rawRight)) >>= evalEither
    actual === flatExpected 0 operation storedLeft storedRight

propNames :: Property
propNames = property $ do
  f <- evalEither fixture
  left <- forAll (signedEntries (names f))
  right <- forAll (signedEntries (names f))
  leftBytes <- evalEither (Collections.encodeAssetNamesCbor left)
  rightBytes <- evalEither (Collections.encodeAssetNamesCbor right)
  let storedLeft = ordered (namePairs left)
      storedRight = ordered (namePairs right)
  classify "duplicate names" (length left > Map.size (Map.fromList left))
  forM_ [0 .. 3] $ \operation -> do
    actual <- evalIO (native 1 operation leftBytes rightBytes) >>= evalEither
    actual === flatExpected 1 operation storedLeft storedRight

propWithdrawals :: Property
propWithdrawals = property $ do
  f <- evalEither fixture
  left <- forAll (Gen.list (Range.linear 0 12) ((,) <$> Gen.element (accounts f) <*> Gen.word64 (Range.linear 0 1000000)))
  right <- forAll (Gen.list (Range.linear 0 12) ((,) <$> Gen.element (accounts f) <*> Gen.word64 (Range.linear 0 1000000)))
  let stored values = ordered [(Reward.toBytes account, toInteger amount) | (account, amount) <- values]
  classify "duplicate reward accounts" (length left > Map.size (Map.fromList left))
  forM_ [0, 1] $ \operation -> do
    actual <- evalIO (native 2 operation (Collections.encodeWithdrawalsCbor left) (Collections.encodeWithdrawalsCbor right)) >>= evalEither
    actual === flatExpected 2 operation (stored left) (stored right)

type Policies = Map ByteString Pairs

multiBytes :: [(Policy.PolicyId, [(Name.AssetName, Integer)])] -> Either Error ByteString
multiBytes values = do
  encoded <- traverse (\(policy, entries) -> (\bytes -> E.encodeBytes (Policy.toBytes policy) <> E.encodePreEncoded bytes) <$> Collections.encodeAssetNamesCbor entries) values
  pure (W.toStrictByteString (E.encodeMapLen (fromIntegral (length values)) <> mconcat encoded))

multiState :: [(Policy.PolicyId, [(Name.AssetName, Integer)])] -> Policies
multiState values = Map.fromList [(Policy.toBytes policy, ordered (namePairs entries)) | (policy, entries) <- values]

multiSnapshot :: Policies -> Snapshot
multiSnapshot = Nested . map (second flat) . Map.toList

multiExpected :: Int -> Policies -> Policies -> Reply
multiExpected operation left right = Reply (multiSnapshot result) (multiSnapshot left) (multiSnapshot right) (Just (result == right))
  where
    result = case operation of
      1 -> Map.union right left
      2 -> Map.filter (not . null) (foldl' (combine 1) left (Map.toList right))
      3 -> Map.filter (not . null) (foldl' (combine (-1)) left (Map.toList right))
      4 -> foldl' set left (Map.toList right)
      _ -> left
    combine sign current (policy, values) = Map.alter (Just . maybe (if sign == 1 then values else arithmetic sign [] values) (\previous -> arithmetic sign previous values)) policy current
    set current (_, []) = current
    set current (policy, values) = Map.alter (Just . (`updates` values) . fromMaybe []) policy current

propMulti :: Property
propMulti = property $ do
  f <- evalEither fixture
  let generate = Gen.list (Range.linear 0 5) ((,) <$> Gen.element (policies f) <*> signedEntries (names f))
  left <- forAll generate
  right <- forAll generate
  leftBytes <- evalEither (multiBytes left)
  rightBytes <- evalEither (multiBytes right)
  let storedLeft = multiState left
      storedRight = multiState right
  classify "stored empty policy" (any null (Map.elems storedLeft))
  classify "outer duplicate replacement" (length left > Map.size storedLeft)
  forM_ [0 .. 4] $ \operation -> do
    actual <- evalIO (native 3 operation leftBytes rightBytes) >>= evalEither
    actual === multiExpected operation storedLeft storedRight

checkBoundaries :: IO ()
checkBoundaries = do
  f <- must fixture
  name <- must (Name.fromBytes (B.singleton 97))
  let duplicate = [(name, 1), (name, 0), (name, 3)]
      replacement = [(name, 7)]
  left <- must (Collections.encodeAssetNamesCbor duplicate)
  right <- must (Collections.encodeAssetNamesCbor replacement)
  actual <- native 1 1 left right >>= must
  actual @?= flatExpected 1 1 (namePairs duplicate) (namePairs replacement)
  added <- native 1 2 left (mapBytes []) >>= must
  added @?= flatExpected 1 2 (namePairs duplicate) []
  -- Both signed endpoints are legal stored quantities; no arithmetic is run on
  -- endpoint pairs because unchecked native add/subtract can overflow int64.
  forM_ [toInteger (minBound :: Int64), toInteger (maxBound :: Int64)] $ \amount -> do
    bytes <- must (Collections.encodeAssetNamesCbor [(name, amount)])
    result <- native 1 0 bytes bytes >>= must
    result @?= flatExpected 1 0 [(Name.toBytes name, amount)] [(Name.toBytes name, amount)]
  account <- case accounts f of
    value : _ -> pure value
    [] -> assertFailure "missing account fixture" >> fail "fixture"
  let withdrawals = [(account, 0), (account, maxBound :: Word64)]
      entries = [(Reward.toBytes account, 0), (Reward.toBytes account, toInteger (maxBound :: Word64))]
  reply <- native 2 1 (Collections.encodeWithdrawalsCbor withdrawals) (Collections.encodeWithdrawalsCbor [(account, 1)]) >>= must
  reply @?= flatExpected 2 1 entries [(Reward.toBytes account, 1)]
  policy <- case policies f of
    value : _ -> pure value
    [] -> assertFailure "missing policy fixture" >> fail "fixture"
  emptyPolicy <- must (multiBytes [(policy, [])])
  absentPolicy <- must (multiBytes [])
  zeros <- must (multiBytes [(policy, [(name, 0)])])
  forM_ [(emptyPolicy, absentPolicy, False), (zeros, emptyPolicy, False), (emptyPolicy, emptyPolicy, True)] $ \(a, b, equal) -> do
    Reply _ _ _ observedEqual <- native 3 0 a b >>= must
    observedEqual @?= Just equal

checkFailures :: IO ()
checkFailures = do
  forM_ [0 .. 3] $ \kind -> do
    forM_ [B.empty, B.singleton 128, B.pack [161, 64, 128], B.pack [160, 0]] $ \invalid ->
      replicateM_ 3 (native kind 0 invalid (B.singleton 160) >>= assertBool "invalid collection accepted" . isLeft)
    native kind 0 (B.singleton 160) (B.singleton 160) >>= must >>= \reply ->
      reply @?= if kind == 3 then Reply (Nested []) (Nested []) (Nested []) (Just True) else flatExpected kind 0 [] []

-- The test wire uses cborg only to expose native getter snapshots; expected
-- states are calculated by ordinary Haskell maps/lists before native execution.
native :: Int -> Int -> ByteString -> ByteString -> IO (Either String Reply)
native kind operation left right = B.useAsCStringLen left $ \(a, aSize) -> B.useAsCStringLen right $ \(b, bSize) ->
  allocaBytes 65536 $ \output -> alloca $ \size -> do
    code <- cOperation (fromIntegral kind) (fromIntegral operation) (castPtr a) (fromIntegral aSize) (castPtr b) (fromIntegral bSize) output 65536 size
    if code /= 0
      then pure (Left ("native collection status " <> show code))
      else do
        count <- peek size
        bytes <- B.packCStringLen (castPtr output, fromIntegral count)
        pure $ case R.deserialiseFromBytes (replyDecoder kind) (L.fromStrict bytes) of
          Left failure -> Left (show failure)
          Right (rest, value) | L.null rest -> Right value
          Right _ -> Left "Trailing native snapshot bytes"

replyDecoder :: Int -> D.Decoder s Reply
replyDecoder kind = do
  size <- D.decodeListLen
  if size /= 4 then fail "Expected collection reply" else Reply <$> snapshotDecoder kind <*> snapshotDecoder kind <*> snapshotDecoder kind <*> optionalBool

optionalBool :: D.Decoder s (Maybe Bool)
optionalBool = do
  token <- D.peekTokenType
  if token == D.TypeNull then D.decodeNull >> pure Nothing else Just <$> D.decodeBool

snapshotDecoder :: Int -> D.Decoder s Snapshot
snapshotDecoder 3 = do
  count <- D.decodeMapLen
  Nested <$> replicateM count ((,) <$> D.decodeBytes <*> snapshotDecoder 1)
snapshotDecoder _ = do
  arity <- D.decodeListLen
  if arity /= 2
    then fail "Expected raw map snapshot"
    else do
      count <- D.decodeMapLen
      pairs <- replicateM count ((,) <$> D.decodeBytes <*> D.decodeInteger)
      lookups <- D.decodeListLen >>= (`replicateM` D.decodeInteger)
      pure (Flat pairs lookups)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_collection_operation"
  cOperation :: CUInt -> CUInt -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt
