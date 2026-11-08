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

module ProtocolValues (tests) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Protocol.CostModels as Costs
import qualified Cometa.Protocol.DRepVotingThresholds as DRep
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as ExUnits
import qualified Cometa.Protocol.PoolVotingThresholds as Pool
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.UnitInterval as Unit
import Data.Bits (testBit)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Either (isLeft)
import Data.Foldable (traverse_)
import Data.Ratio ((%))
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Protocol values"
    [ testCase "fraction bounds, numeric comparison and pair retention" checkRationals,
      testCase "tuple bounds and malformed CBOR" checkBounds,
      testCase "pinned native corpus values and invalid rational regression" checkCorpus,
      testCase "future cost language, signed costs and replacement" checkCosts,
      testCase "language views preserve V1 encoding and match native subsets" checkLanguageViews,
      testCase "typed native construction agrees with all foundational codecs" checkNative,
      testProperty "exact fractions preserve pairs and numeric order" propFractions,
      testProperty "full-width budgets agree with typed native construction" propBudgets
    ]

checkRationals :: IO ()
checkRationals = do
  half <- expectRight (Rational.mkNonNegativeRational 1 2)
  unreduced <- expectRight (Rational.mkNonNegativeRational 2 4)
  half @?= unreduced
  compare half unreduced @?= EQ
  Rational.toRational unreduced @?= (1 % 2)
  Rational.numerator unreduced @?= 2
  Rational.denominator unreduced @?= 4
  assertBool "wire pairs retained" (Rational.encodeCbor half /= Rational.encodeCbor unreduced)
  traverse_
    (\(n, d) -> Rational.mkNonNegativeRational n d @?= Left (InvalidProtocolRational n d))
    [(-1, 1), (1, 0), (1, -1), (2 ^ (64 :: Int), 1), (1, 2 ^ (64 :: Int))]
  Unit.mkUnitInterval 2 1 @?= Left (InvalidUnitInterval 2 1)
  traverse_ (expectRight . uncurry Unit.mkUnitInterval) [(0, 1), (1, 1), (2, 4)]
  large <- expectRight (Rational.mkNonNegativeRational 2 1)
  Prices.decodeCbor (Prices.encodeCbor (Prices.ExUnitPrices large half)) @?= Right (Prices.ExUnitPrices large half)

checkBounds :: IO ()
checkBounds = do
  ExUnits.mkExUnits (-1) 0 @?= Left (InvalidExUnits (-1) 0)
  ExUnits.mkExUnits 0 (2 ^ (64 :: Int)) @?= Left (InvalidExUnits 0 (2 ^ (64 :: Int)))
  Version.mkProtocolVersion 0 (2 ^ (32 :: Int)) @?= Left (InvalidProtocolVersion 0 (2 ^ (32 :: Int)))
  Version.decodeCbor (Version.encodeCbor (Version.ProtocolVersion maxBound maxBound)) @?= Right (Version.ProtocolVersion maxBound maxBound)
  traverse_
    (assertBool "reject malformed rational" . isLeft . Rational.decodeCbor . BS.pack)
    [[0x82, 1, 2], [0xd8, 30, 0x82, 1, 0], [0xd8, 30, 0x81, 1], [0xd8, 30, 0x83, 1, 2, 3], [0xd8, 30, 0x82, 1, 2, 0]]
  Unit.decodeCbor (BS.pack [0xd8, 30, 0x82, 2, 1]) `assertLeft` "unit upper bound"
  ExUnits.decodeCbor (BS.pack [0x9f, 1, 2, 0xff]) @?= Right (ExUnits.ExUnits 1 2)
  ExUnits.decodeCbor (BS.pack [0x9f, 1, 2, 3, 0xff]) `assertLeft` "extra indefinite field"
  Version.decodeCbor (BS.pack [0x82, 0, 0x1b, 0, 0, 0, 1, 0, 0, 0, 0]) `assertLeft` "minor u32 bound"

-- Native vectors: cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/common/{unit_interval,ex_units,protocol_version}.cpp and
-- lib/tests/protocol_params/{ex_unit_prices,pool_voting_thresholds}.cpp;
-- Apache-2.0. Bytes below transcribe the named CBOR constants.
checkCorpus :: IO ()
checkCorpus = do
  fraction <- expectRight (Rational.decodeCbor (BS.pack [0xd8, 30, 0x82, 1, 5]))
  Rational.numerator fraction @?= 1
  Rational.denominator fraction @?= 5
  Version.decodeCbor (BS.pack [0x82, 1, 3]) @?= Right (Version.ProtocolVersion 1 3)
  budget <- expectRight (ExUnits.decodeCbor (BS.pack [0x82, 0x1b, 0, 0, 0x86, 0x78, 0x8f, 0xfc, 0x4e, 0x83, 0x1b, 0, 1, 0x50, 0x60, 0xe9, 0xe4, 0x64, 0x51]))
  ExUnits.memory budget @?= 0x86788ffc4e83
  ExUnits.steps budget @?= 0x15060e9e46451
  prices <- expectRight (Prices.decodeCbor (BS.pack [0x82, 0xd8, 30, 0x82, 1, 2, 0xd8, 30, 0x82, 1, 3]))
  Rational.toRational (Prices.memoryPrice prices) @?= (1 % 2)
  Rational.toRational (Prices.stepPrice prices) @?= (1 % 3)
  -- Native pool fixture starts with 0/0; a proportion cannot have denominator 0.
  Pool.decodeCbor (BS.pack [0x85, 0xd8, 30, 0x82, 0, 0, 0xd8, 30, 0x82, 1, 1, 0xd8, 30, 0x82, 2, 2, 0xd8, 30, 0x82, 3, 3, 0xd8, 30, 0x82, 4, 4]) `assertLeft` "undefined native proportion"

checkCosts :: IO ()
checkCosts = do
  future <- expectRight (Costs.mkCostModel 255 [minBound, 0, maxBound])
  replacement <- expectRight (Costs.mkCostModel 255 [7])
  original <- expectRight (Costs.mkCostModel 0 [])
  let models = Costs.fromList [future, original, replacement]
  Costs.lookup 255 models @?= Just replacement
  fmap Costs.languageId (Costs.toList models) @?= [0, 255]
  Costs.decodeCbor (Costs.encodeCbor models) @?= Right models
  Costs.decodeCostModelCbor 255 (Costs.encodeCostModelCbor future) @?= Right future
  Costs.mkCostModel 0 (replicate 2049 0) @?= Left (InvalidCostModelLength 2049)
  full <- expectRight (Costs.mkCostModel 0 (replicate 2048 0))
  Costs.decodeCostModelCbor 0 (Costs.encodeCostModelCbor full) @?= Right full
  Costs.decodeCbor (BS.pack [0xa2, 0, 0x80, 0, 0x80]) `assertLeft` "duplicate language"
  Costs.decodeCbor (BS.pack [0xa1, 0x19, 1, 0, 0x80]) `assertLeft` "language u8 bound"
  Costs.decodeCostModelCbor 0 (BS.pack ([0x9f] ++ replicate 2049 0 ++ [0xff])) `assertLeft` "indefinite vector bound"
  indefinite <- expectRight (Costs.decodeCostModelCbor 255 (BS.pack [0x9f, 0x20, 0, 0xff]))
  Costs.costs indefinite @?= [-1, 0]
  Costs.decodeCostModelCbor 0 (BS.pack [0x81, 0x1b, 0x80, 0, 0, 0, 0, 0, 0, 0]) `assertLeft` "int64 overflow"

checkNative :: IO ()
checkNative = do
  r <- expectRight (Rational.mkNonNegativeRational 2 4)
  u <- expectRight (Unit.mkUnitInterval 2 4)
  otherR <- expectRight (Rational.mkNonNegativeRational 4 6)
  otherU <- expectRight (Unit.mkUnitInterval 4 6)
  let prices = Prices.ExUnitPrices r otherR
      pool = Pool.PoolVotingThresholds u otherU u otherU u
      drep = DRep.DRepVotingThresholds u otherU u otherU u otherU u otherU u otherU
  m <- expectRight (Costs.mkCostModel 0 [-1, 0, maxBound])
  let cases = [(0, Rational.encodeCbor r), (1, ExUnits.encodeCbor (ExUnits.ExUnits 2 4)), (2, Version.encodeCbor (Version.ProtocolVersion 2 4)), (3, Prices.encodeCbor prices), (4, Pool.encodeCbor pool), (5, DRep.encodeCbor drep), (6, Costs.encodeCbor (Costs.fromList [m]))]
  traverse_ (\(kind, bytes) -> oracle kind 2 4 >>= (@?= bytes)) cases
  Pool.decodeCbor (Pool.encodeCbor pool) @?= Right pool
  DRep.decodeCbor (DRep.encodeCbor drep) @?= Right drep

propFractions :: Property
propFractions = property $ do
  n <- forAll (Gen.word64 Range.constantBounded)
  d <- forAll (Gen.word64 (Range.constant 1 maxBound))
  r <- evalEither (Rational.mkNonNegativeRational (toInteger n) (toInteger d))
  decoded <- evalEither (Rational.decodeCbor (Rational.encodeCbor r))
  Rational.numerator decoded === n
  Rational.denominator decoded === d
  Rational.toRational decoded === (toInteger n % toInteger d)
  otherN <- forAll (Gen.word64 Range.constantBounded)
  otherD <- forAll (Gen.word64 (Range.constant 1 maxBound))
  other <- evalEither (Rational.mkNonNegativeRational (toInteger otherN) (toInteger otherD))
  compare r other === compare (toInteger n % toInteger d) (toInteger otherN % toInteger otherD)
  native <- evalIO (oracle 0 n d)
  Rational.encodeCbor r === native

propBudgets :: Property
propBudgets = property $ do
  m <- forAll (Gen.word64 Range.constantBounded)
  s <- forAll (Gen.word64 Range.constantBounded)
  let budget = ExUnits.ExUnits m s
  ExUnits.decodeCbor (ExUnits.encodeCbor budget) === Right budget
  native <- evalIO (oracle 1 m s)
  ExUnits.encodeCbor budget === native

assertLeft :: Either a b -> String -> IO ()
assertLeft value label = assertBool label (isLeft value)

expectRight :: (Show e) => Either e a -> IO a
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure (show failure) >> fail "unreachable"

oracle :: Word8 -> Word64 -> Word64 -> IO ByteString
oracle kind first second = allocaBytes 1024 $ \output -> alloca $ \size -> do
  status <- cOracle kind first second (castPtr output) 1024 size
  status @?= 0
  count <- peek size
  BS.packCStringLen (castPtr output, fromIntegral count)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_protocol_values_oracle"
  cOracle :: Word8 -> Word64 -> Word64 -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt

-- Native oracle: pinned costmdls.c, known language views; exact V1 bytes are
-- independently stated below, including the historical indefinite-array defect.
checkLanguageViews :: IO ()
checkLanguageViews = do
  Costs.encodeLanguageViews Costs.empty @?= BS.singleton 0xa0
  one <- expectRight (Costs.mkCostModel 0 [1, -2])
  Costs.encodeLanguageViews (Costs.fromList [one])
    @?= BS.pack [0xa1, 0x41, 0, 0x44, 0x9f, 1, 0x21, 0xff]
  forEachMask [0 .. 31]
  where
    forEachMask = traverse_ $ \mask -> do
      models <-
        traverse
          (\language -> expectRight (Costs.mkCostModel language [minBound, -1, 0, maxBound]))
          [if bit == 4 then 255 else fromIntegral bit | bit <- [0 .. 4], testBit mask bit]
      native <- oracle 7 mask 0
      Costs.encodeLanguageViews (Costs.fromList models) @?= native
