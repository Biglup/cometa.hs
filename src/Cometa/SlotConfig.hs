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

-- | Convert between slots and Unix milliseconds within a period of constant
-- slot duration. A configuration applies from its reference slot onwards; it
-- does not describe earlier eras or predict future changes in slot duration.
--
-- @
-- import qualified Cometa.SlotConfig as Slots
--
-- firstMillisecond = Slots.slotToTime Slots.preview 100
-- enclosingSlot = firstMillisecond >>= Slots.timeToSlot Slots.preview
-- @
module Cometa.SlotConfig
  ( SlotConfig,
    mkSlotConfig,
    zeroTime,
    zeroSlot,
    slotLength,
    mainnet,
    preview,
    preprod,
    slotToTime,
    timeToSlot,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (InvalidSlotConfig))
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | A reference slot, its Unix start time, and a positive slot duration.
-- Equality compares these three values.
data SlotConfig = SlotConfig !Word64 !Word64 !Word64
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Construct a constant-duration schedule. A zero duration is rejected.
mkSlotConfig ::
  -- | Unix start time of the reference slot, in milliseconds.
  Word64 ->
  -- | Reference slot number.
  Word64 ->
  -- | Duration of one slot, in milliseconds; must be positive.
  Word64 ->
  Either Error SlotConfig
mkSlotConfig _ _ 0 = Left (InvalidSlotConfig "Slot duration must be positive")
mkSlotConfig time slot duration = Right (SlotConfig time slot duration)

-- | Unix start time of the reference slot, in milliseconds.
zeroTime :: SlotConfig -> Word64
zeroTime (SlotConfig time _ _) = time

-- | First slot described by this configuration.
zeroSlot :: SlotConfig -> Word64
zeroSlot (SlotConfig _ slot _) = slot

-- | Positive duration of each slot, in milliseconds.
slotLength :: SlotConfig -> Word64
slotLength (SlotConfig _ _ duration) = duration

-- | Mainnet's one-second schedule starting at slot 4,492,800.
-- Earlier Byron slots require a different configuration.
mainnet :: SlotConfig
mainnet = SlotConfig 1596059091000 4492800 1000

-- | Preview's one-second schedule starting at slot zero.
preview :: SlotConfig
preview = SlotConfig 1666656000000 0 1000

-- | Preprod's one-second schedule starting at slot 86,400.
preprod :: SlotConfig
preprod = SlotConfig 1655769600000 86400 1000

-- | Return the Unix start time of a slot, in milliseconds. Slots before the
-- reference slot and times greater than 2^64 - 1 are rejected.
slotToTime :: SlotConfig -> Word64 -> Either Error Word64
slotToTime config slot
  | slot < zeroSlot config = Left (InvalidSlotConfig "Slot precedes the reference slot")
  | otherwise = bounded (toInteger (zeroTime config) + (toInteger slot - toInteger (zeroSlot config)) * toInteger (slotLength config))

-- | Return the slot containing a Unix timestamp in milliseconds. A slot includes
-- its start instant and excludes the next slot's start. Times before the reference
-- time and resulting slots greater than 2^64 - 1 are rejected.
timeToSlot :: SlotConfig -> Word64 -> Either Error Word64
timeToSlot config time
  | time < zeroTime config = Left (InvalidSlotConfig "Time precedes the reference time")
  | otherwise = bounded (toInteger (zeroSlot config) + (toInteger time - toInteger (zeroTime config)) `div` toInteger (slotLength config))

bounded :: Integer -> Either Error Word64
bounded value
  | value > toInteger (maxBound :: Word64) = Left (InvalidSlotConfig "Conversion exceeds the unsigned 64-bit range")
  | otherwise = Right (fromInteger value)
