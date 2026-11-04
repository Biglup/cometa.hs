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

-- | Private transaction representation evidence, not a public transaction API.
-- Imported and synthetic signed bytes have independent hashes and signature
-- verification provenance in test/Fixtures/TRANSACTIONS.md.
module Transaction (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Encoding.Cbor as Cbor
import Cometa.Internal.Hex (decodeHex, encodeHex)
import qualified Cometa.Internal.Transaction as Tx
import Control.Monad (replicateM_, (>=>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Word (Word64, Word8)
import Fixtures.Transaction (Fixture (..))
import qualified Fixtures.Transaction as Fixture
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
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
    "Private transaction encoding prototype"
    [ testCase "historical and noncanonical signed encodings retain exact identity" $ mapM_ checkIdentity Fixture.allFixtures,
      testCase "native oracle verifies signed digests and decoded field snapshots" $ mapM_ checkNativeAgreement Fixture.allFixtures,
      testCase "typed body inspection retains fee and field order" checkBodyFields,
      testCase "setting the same fee is an exact no-op" $ mapM_ checkSameFee Fixture.allFixtures,
      testCase "changed fee invalidates body bytes and removes signatures" checkChangedFee,
      testCase "fee edit retains native scripts, datums and redeemers" checkWitnessRetention,
      testCase "sibling edits and copied snapshots remain independent" checkEditIndependence,
      testCase "malformed, incomplete and trailing transactions are rejected" checkInvalidTransactions,
      testCase "legacy, block and indefinite frames retain exact identity" checkFrameLayouts,
      testCase "repeated decode/edit snapshots survive native cleanup and GC" checkLifecycle,
      testProperty "fee edit round trips without changing its source" propFeeEdit
    ]

checkIdentity :: Fixture -> IO ()
checkIdentity fixture = do
  bytes <- hexBytes (transactionHex fixture)
  tx <- requireRight (Tx.decodeCbor bytes)
  Tx.encodeCbor tx @?= bytes
  encodeHex (Tx.bodyCbor tx) @?= bodyHex fixture
  encodeHex (Tx.witnessCbor tx) @?= witnessHex fixture
  encodeHex (Tx.bodyHash tx) @?= hashHex fixture
  Tx.fee tx @?= expectedFee fixture
  -- The hash expectation was computed independently; this additionally checks
  -- agreement with the public hashing operation on the exact body snapshot.
  digest <- requireRight (Blake2b.compute 32 (Tx.bodyCbor tx))
  Blake2b.toBytes digest @?= Tx.bodyHash tx

checkNativeAgreement :: Fixture -> IO ()
checkNativeAgreement fixture = do
  bytes <- hexBytes (transactionHex fixture)
  tx <- requireRight (Tx.decodeCbor bytes)
  (nativeFee, nativeHash, counts) <- nativeSnapshot bytes
  nativeFee @?= Tx.fee tx
  nativeHash @?= Tx.bodyHash tx
  counts @?= expectedCounts fixture
  -- The oracle verifies each retained verification-key signature over precisely
  -- the body digest whose independent value is pinned in the fixture.
  encodeHex nativeHash @?= hashHex fixture

checkBodyFields :: IO ()
checkBodyFields = do
  bytes <- hexBytes (transactionHex Fixture.noncanonical)
  tx <- requireRight (Tx.decodeCbor bytes)
  body <- requireRight (Cbor.fromBytes (Tx.bodyCbor tx))
  entries <- requireRight (Cbor.decodeMap body)
  map (Cbor.toHex . fst) entries @?= ["02", "01", "00"]
  case entries of
    [(_, feeValue), (_, outputs), (_, inputs)] -> do
      Cbor.decodeInteger feeValue >>= (@?= Right 10)
      Cbor.decodeArray outputs >>= (@?= Right [])
      Cbor.toHex inputs @?= "d9010280"
    _ -> assertFailure "unexpected noncanonical body fields"

checkSameFee :: Fixture -> IO ()
checkSameFee fixture = do
  bytes <- hexBytes (transactionHex fixture)
  tx <- requireRight (Tx.decodeCbor bytes)
  edited <- requireRight (Tx.setFee (Tx.fee tx) tx)
  edited @?= tx
  Tx.encodeCbor edited @?= bytes
  Tx.bodyHash edited @?= Tx.bodyHash tx
  Tx.witnessCbor edited @?= Tx.witnessCbor tx

checkChangedFee :: IO ()
checkChangedFee = do
  original <- decodeFixture Fixture.noncanonical
  edited <- requireRight (Tx.setFee 42 original)
  Tx.fee edited @?= 42
  encodeHex (Tx.bodyCbor edited) @?= "a300d9010280018002182a"
  encodeHex (Tx.bodyHash edited) @?= "a5412fe55fd15ed71f2e55fdb9c4f8a3105f8e41cb770e2ed848f73f0382a38b"
  encodeHex (Tx.witnessCbor edited) @?= "a0"
  assertBool "body change retained its old hash" (Tx.bodyHash edited /= Tx.bodyHash original)
  reparsed <- requireRight (Tx.decodeCbor (Tx.encodeCbor edited))
  reparsed @?= edited
  (nativeFee, nativeHash, counts) <- nativeSnapshot (Tx.encodeCbor edited)
  nativeFee @?= 42
  nativeHash @?= Tx.bodyHash edited
  counts @?= [0, 0, 0, 0, 0, 0]

checkWitnessRetention :: IO ()
checkWitnessRetention = do
  original <- decodeFixture Fixture.rich
  before <- witnessEntries original
  edited <- requireRight (Tx.setFee 42 original)
  after <- witnessEntries edited
  map fst before @?= [0, 1, 2, 4, 5]
  map fst after @?= [1, 4, 5]
  after @?= filter (\(key, _) -> key /= 0 && key /= 2) before
  (_, _, counts) <- nativeSnapshot (Tx.encodeCbor edited)
  counts @?= [0, 0, 1, 1, 1, 0]
  encodeHex (Tx.witnessCbor original) @?= witnessHex Fixture.rich
  auxiliaryHex original >>= (@?= "a1017803617578")
  auxiliaryHex edited >>= (@?= "a1017803617578")

checkEditIndependence :: IO ()
checkEditIndependence = do
  original <- decodeFixture Fixture.rich
  let body = Tx.bodyCbor original
      witness = Tx.witnessCbor original
      digest = Tx.bodyHash original
  first <- requireRight (Tx.setFee 42 original)
  second <- requireRight (Tx.setFee 43 original)
  performGC
  Tx.fee original @?= 10
  Tx.bodyCbor original @?= body
  Tx.witnessCbor original @?= witness
  Tx.bodyHash original @?= digest
  map Tx.fee [first, second] @?= [42, 43]
  assertBool "sibling edits share a stale body hash" (Tx.bodyHash first /= Tx.bodyHash second)

checkInvalidTransactions :: IO ()
checkInvalidTransactions = do
  valid <- hexBytes (transactionHex Fixture.noncanonical)
  let malformed = [ByteString.empty, ByteString.singleton 0, ByteString.take 1 valid, ByteString.init valid, valid <> ByteString.singleton 0]
  mapM_ check malformed
  mapM_ (hexBytes >=> check) ["82a0a0", "84a0a0f5f6", "84a200800180a0f5f6", "84a3008001800220a0f5f6", "84a400d9010280018002010202a0f5f6", "84a300d90102800180020aa200800080f5f6"]
  where
    check bytes = Tx.decodeCbor bytes >>= assertBool "malformed transaction accepted" . isLeft

checkFrameLayouts :: IO ()
checkFrameLayouts = do
  original <- hexBytes (transactionHex Fixture.noncanonical)
  let fields = ByteString.take (ByteString.length original - 2) original
      legacyFalse = fields <> ByteString.pack [0xf4, 0xf6]
      blockTrue = fields <> ByteString.pack [0xf6, 0xf5]
      blockFalse = fields <> ByteString.pack [0xf6, 0xf4]
      indefinite bytes = ByteString.singleton 0x9f <> ByteString.drop 1 bytes <> ByteString.singleton 0xff
  mapM_ (uncurry check) [(original, ["f5", "f6"]), (legacyFalse, ["f4", "f6"]), (blockTrue, ["f6", "f5"]), (blockFalse, ["f6", "f4"]), (indefinite original, ["f5", "f6"]), (indefinite blockTrue, ["f6", "f5"])]
  where
    check bytes suffix = do
      tx <- requireRight (Tx.decodeCbor bytes)
      Tx.encodeCbor tx @?= bytes
      encodeHex (Tx.bodyHash tx) @?= hashHex Fixture.noncanonical
      same <- requireRight (Tx.setFee 10 tx)
      Tx.encodeCbor same @?= bytes
      edited <- requireRight (Tx.setFee 42 tx)
      frame <- requireRight (Cbor.fromBytes (Tx.encodeCbor edited))
      fields <- requireRight (Cbor.decodeArray frame)
      map Cbor.toHex (drop 2 fields) @?= suffix

checkLifecycle :: IO ()
checkLifecycle = do
  original <- decodeFixture Fixture.rich
  edited <- requireRight (Tx.setFee 42 original)
  replicateM_ 100 $ do
    temporary <- decodeFixture Fixture.historical
    _ <- requireRight (Tx.setFee 42 temporary)
    _ <- decodeFixture Fixture.rich
    pure ()
  performGC
  encodeHex (Tx.bodyHash original) @?= hashHex Fixture.rich
  encodeHex (Tx.witnessCbor original) @?= witnessHex Fixture.rich
  Tx.fee edited @?= 42
  checkIdentity Fixture.historical

propFeeEdit :: Property
propFeeEdit = withTests 300 $ property $ do
  fee <- forAll (Gen.word64 Range.constantBounded)
  original <- evalIO (decodeFixture Fixture.rich)
  edited <- evalIO (Tx.setFee fee original) >>= evalEither
  Tx.fee edited === fee
  Tx.fee original === 10
  encodeHex (Tx.bodyHash original) === hashHex Fixture.rich
  encodeHex (Tx.witnessCbor original) === witnessHex Fixture.rich
  decoded <- evalIO (Tx.decodeCbor (Tx.encodeCbor edited)) >>= evalEither
  Tx.fee decoded === fee
  Tx.bodyHash decoded === Tx.bodyHash edited
  Tx.bodyCbor decoded === Tx.bodyCbor edited
  Tx.witnessCbor decoded === Tx.witnessCbor edited

witnessEntries :: Tx.Transaction -> IO [(Integer, ByteString)]
witnessEntries tx = do
  value <- requireRight (Cbor.fromBytes (Tx.witnessCbor tx))
  pairs <- requireRight (Cbor.decodeMap value)
  mapM
    ( \(key, item) -> do
        number <- requireRight (Cbor.decodeInteger key)
        pure (number, Cbor.toBytes item)
    )
    pairs

auxiliaryHex :: Tx.Transaction -> IO Text
auxiliaryHex tx = do
  frame <- requireRight (Cbor.fromBytes (Tx.encodeCbor tx))
  fields <- requireRight (Cbor.decodeArray frame)
  case fields of
    [_, _, _, auxiliary] -> pure (Cbor.toHex auxiliary)
    _ -> assertFailure "expected a legacy four-element fixture" >> fail "invalid frame"

decodeFixture :: Fixture -> IO Tx.Transaction
decodeFixture fixture = hexBytes (transactionHex fixture) >>= requireRight . Tx.decodeCbor

hexBytes :: Text -> IO ByteString
hexBytes text = case decodeHex text of
  Just bytes -> pure bytes
  Nothing -> assertFailure "invalid hexadecimal fixture" >> fail "invalid fixture"

requireRight :: (Show failure) => IO (Either failure value) -> IO value
requireRight action = do
  result <- action
  case result of
    Right value -> pure value
    Left failure -> assertFailure (show failure) >> fail "transaction fixture operation failed"

nativeSnapshot :: ByteString -> IO (Word64, ByteString, [Word64])
nativeSnapshot bytes =
  ByteString.useAsCStringLen bytes $ \(input, size) ->
    alloca $ \fee -> allocaArray 32 $ \hash -> allocaArray 6 $ \counts -> do
      status <- cTransactionOracle (castPtr input) (fromIntegral size) fee hash counts
      status @?= 0
      nativeFee <- peek fee
      nativeHash <- ByteString.packCStringLen (castPtr hash, 32)
      nativeCounts <- peekArray 6 counts
      pure (nativeFee, nativeHash, nativeCounts)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_transaction_oracle"
  cTransactionOracle :: Ptr Word8 -> CSize -> Ptr Word64 -> Ptr Word8 -> Ptr Word64 -> IO CUInt
