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

module AssetId (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import Cometa.Error (Error (..))
import qualified Cometa.PolicyId as PolicyId
import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalEither, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Native asset identity codecs and fingerprints"
    [ testCase "binary and hex length boundaries" checkBounds,
      testCase "Ada is distinct from an empty native name" checkAda,
      testCase "native codec correspondence at every allowed name length" checkNative,
      testCase "CIP-14 official fingerprints" checkFingerprints,
      testProperty "exact native byte and hex round trips" propRoundTrip
    ]

checkBounds :: IO ()
checkBounds = do
  forM_ [0, 1, 27, 61, 64] $ \size -> do
    AssetId.fromBytes (ByteString.replicate size 0) @?= Left (InvalidAssetIdLength size)
    AssetId.fromHex (Text.replicate size "00") @?= Left (InvalidAssetIdLength size)
  forM_ ["a", "gg", "0x00", " 00", "１２", "00\n"] $ \text ->
    AssetId.fromHex text @?= Left InvalidHex
  forM_ [28, 60] $ \size -> do
    asset <- expectRight (AssetId.fromHex (Text.replicate size "Ab"))
    AssetId.toHex asset @?= Right (Text.replicate size "ab")
    AssetId.toBytes asset @?= Right (ByteString.replicate size 171)

checkAda :: IO ()
checkAda = do
  assertUnsupported (AssetId.toBytes AssetId.Ada)
  assertUnsupported (AssetId.toHex AssetId.Ada)
  AssetId.fingerprint AssetId.Ada >>= assertUnsupported
  policy <- expectRight (PolicyId.fromBytes (ByteString.replicate 28 0))
  let native = AssetId.Native policy AssetName.empty
  AssetId.fromBytes (ByteString.replicate 28 0) @?= Right native
  (native == AssetId.Ada) @?= False

checkNative :: IO ()
checkNative = forM_ [0 .. 32] $ \nameSize -> do
  let bytes = ByteString.pack ([0 .. 27] <> take nameSize (cycle [0, 255, 128, 65]))
  asset <- expectRight (AssetId.fromBytes bytes)
  text <- expectRight (AssetId.toHex asset)
  ByteString.useAsCStringLen bytes $ \(raw, size) ->
    ByteString.useAsCStringLen (ByteString.pack (map (fromIntegral . fromEnum) (Text.unpack text))) $ \(hex, hexSize) -> do
      result <- cAgreement (castPtr raw) (fromIntegral size) (castPtr hex) (fromIntegral hexSize)
      result @?= 1

checkFingerprints :: IO ()
checkFingerprints = forM_ fingerprintVectors $ \(policy, name, expected) -> do
  asset <- expectRight (AssetId.fromHex (policy <> name))
  AssetId.fingerprint asset >>= (@?= Right expected)

-- Official CIP-0014 vectors, Matthias Benkort and Rodney Lorrimar, CC-BY-4.0.
-- https://github.com/cardano-foundation/CIPs/blob/86b89208d3b2aabb5dcc5b778dfbe09096b4e114/CIP-0014/README.md
-- Values are decoded from hex before hashing; no UTF-8 asset-name conversion.
fingerprintVectors :: [(Text, Text, Text)]
fingerprintVectors =
  [ ("7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373", "", "asset1rjklcrnsdzqp65wjgrg55sy9723kw09mlgvlc3"),
    ("7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc37e", "", "asset1nl0puwxmhas8fawxp8nx4e2q3wekg969n2auw3"),
    ("1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209", "", "asset1uyuxku60yqe57nusqzjx38aan3f2wq6s93f6ea"),
    ("7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373", "504154415445", "asset13n25uv0yaf5kus35fm2k86cqy60z58d9xmde92"),
    ("1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209", "504154415445", "asset1hv4p5tv2a837mzqrst04d0dcptdjmluqvdx9k3"),
    ("1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209", "7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373", "asset1aqrdypg669jgazruv5ah07nuyqe0wxjhe2el6f"),
    ("7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373", "1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209", "asset17jd78wukhtrnmjh3fngzasxm8rck0l2r4hhyyt"),
    ("7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373", "0000000000000000000000000000000000000000000000000000000000000000", "asset1pkpwyknlvul7az0xx8czhl60pyel45rpje4z8w")
  ]

propRoundTrip :: Property
propRoundTrip = property $ do
  policyBytes <- forAll (Gen.bytes (Range.singleton 28))
  nameBytes <- forAll (Gen.bytes (Range.linear 0 32))
  policy <- evalEither (PolicyId.fromBytes policyBytes)
  name <- evalEither (AssetName.fromBytes nameBytes)
  let asset = AssetId.Native policy name
      bytes = policyBytes <> nameBytes
  AssetId.toBytes asset === Right bytes
  AssetId.fromBytes bytes === Right asset
  text <- evalEither (AssetId.toHex asset)
  AssetId.fromHex text === Right asset
  AssetId.fromHex (Text.toUpper text) === Right asset

expectRight :: (Show failure) => Either failure value -> IO value
expectRight result = case result of
  Left failure -> assertFailure (show failure) >> fail "unexpected Left"
  Right value -> pure value

assertUnsupported :: (Show value) => Either Error value -> IO ()
assertUnsupported (Left (UnsupportedOperation _)) = pure ()
assertUnsupported result = assertFailure ("expected UnsupportedOperation, got " <> show result)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_asset_id_codecs"
  cAgreement :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CInt
