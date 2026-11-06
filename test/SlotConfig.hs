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

module SlotConfig (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.SlotConfig as Slots
import Data.Either (isLeft)
import Data.Word (Word64)
import Foreign.C.Types (CUInt (..))
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Slot configuration"
    [ testCase "network schedules match native constants" presets,
      testCase "zero duration, earlier periods and unsigned overflow are rejected" bounds,
      testProperty "slot starts and enclosing instants agree with native arithmetic" conversions
    ]

presets :: IO ()
presets = mapM_ check (zip [0 ..] [Slots.mainnet, Slots.preview, Slots.preprod])
  where
    check (network, config) = do
      actualTime <- cPreset network 0
      actualSlot <- cPreset network 1
      actualLength <- cPreset network 2
      (Slots.zeroTime config, Slots.zeroSlot config, Slots.slotLength config) @?= (actualTime, actualSlot, actualLength)

bounds :: IO ()
bounds = do
  assertBool "zero duration" (isLeft (Slots.mkSlotConfig 0 0 0))
  assertBool "historical slot" (isLeft (Slots.slotToTime Slots.mainnet (Slots.zeroSlot Slots.mainnet - 1)))
  assertBool "historical time" (isLeft (Slots.timeToSlot Slots.preprod (Slots.zeroTime Slots.preprod - 1)))
  let checked config action = either (const False) (isLeft . action) config
  assertBool "time overflow" (checked (Slots.mkSlotConfig maxBound 0 1) (`Slots.slotToTime` 1))
  assertBool "slot overflow" (checked (Slots.mkSlotConfig 0 maxBound 1) (`Slots.timeToSlot` 1))
  (Slots.mkSlotConfig maxBound maxBound maxBound >>= (`Slots.slotToTime` maxBound)) @?= Right maxBound
  (Slots.mkSlotConfig maxBound maxBound maxBound >>= (`Slots.timeToSlot` maxBound)) @?= Right maxBound

conversions :: Property
conversions = property $ do
  time <- forAll (Gen.word64 (Range.linear 0 10000000000000))
  slot <- forAll (Gen.word64 (Range.linear 0 100000000))
  duration <- forAll (Gen.word64 (Range.linear 1 100000))
  offset <- forAll (Gen.word64 (Range.linear 0 100000000))
  within <- forAll (Gen.word64 (Range.linear 0 (duration - 1)))
  config <- evalEither (Slots.mkSlotConfig time slot duration)
  start <- evalEither (Slots.slotToTime config (slot + offset))
  nativeStart <- evalIO (cSlot time slot duration (slot + offset))
  start === nativeStart
  Slots.timeToSlot config start === Right (slot + offset)
  Slots.timeToSlot config (start + within) === Right (slot + offset)
  nativeSlot <- evalIO (cTime time slot duration (start + within))
  nativeSlot === slot + offset
  Slots.slotToTime config (slot + offset + 1) === Right (start + duration)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_slot_preset"
  cPreset :: CUInt -> CUInt -> IO Word64

foreign import ccall unsafe "cometa_test_slot_begin"
  cSlot :: Word64 -> Word64 -> Word64 -> Word64 -> IO Word64

foreign import ccall unsafe "cometa_test_slot_enclosing"
  cTime :: Word64 -> Word64 -> Word64 -> Word64 -> IO Word64
