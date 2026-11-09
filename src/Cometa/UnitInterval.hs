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

-- | Exact proportions from zero through one, inclusive.
-- Pairs retain their numerator and denominator; comparison is numeric.
--
-- @mkUnitInterval 2 3@ validates a two-thirds voting threshold.
module Cometa.UnitInterval
  ( UnitInterval,
    mkUnitInterval,
    fromDouble,
    toDouble,
    numerator,
    denominator,
    toRational,
    asNonNegativeRational,
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Internal.ProtocolValues (NonNegativeRational, UnitInterval, mkUnitInterval)
import qualified Cometa.Internal.ProtocolValues as Internal
import Data.ByteString (ByteString)
import Data.Word (Word64)
import Prelude hiding (toRational)

-- DEFINITIONS ----------------------------------------------------------------

-- | Convert a finite number in @[0,1]@ using the native decimal-floor rule:
-- reduce @floor(value * 10^15) / 10^15@. This may round down and is not the
-- exact binary rational representation of the Double. NaN, infinities and values
-- outside the interval return 'InvalidUnitIntervalDouble'. Negative zero is zero.
fromDouble :: Double -> Either Error UnitInterval
fromDouble value
  | isNaN value || isInfinite value || value < 0 || value > 1 = Left InvalidUnitIntervalDouble
  | otherwise =
      let n = floor (value * 1000000000000000)
          d = 1000000000000000
          divisor = gcd n d
       in mkUnitInterval (n `quot` divisor) (d `quot` divisor)

-- | Approximate the fraction by converting its numerator and denominator
-- separately to Double and dividing, matching the native conversion. This can
-- differ from rounding an exact Rational once.
toDouble :: UnitInterval -> Double
toDouble value = fromIntegral (numerator value) / fromIntegral (denominator value)

-- | Original unsigned numerator.
numerator :: UnitInterval -> Word64
numerator = Internal.rationalNumerator . Internal.unitIntervalRational

-- | Original positive unsigned denominator.
denominator :: UnitInterval -> Word64
denominator = Internal.rationalDenominator . Internal.unitIntervalRational

-- | Exact numeric proportion.
toRational :: UnitInterval -> Rational
toRational = Internal.rationalValue . Internal.unitIntervalRational

-- | Forget the upper bound while retaining the original fraction pair.
asNonNegativeRational :: UnitInterval -> NonNegativeRational
asNonNegativeRational = Internal.unitIntervalRational

-- | Encode a definite-length ledger CBOR value with shortest integer encodings.
encodeCbor :: UnitInterval -> ByteString
encodeCbor = Internal.encodeBytes Internal.encodeUnitInterval

-- | Decode exactly one ledger CBOR value. Invalid fields or trailing data return
-- 'Cometa.Error.InvalidProtocolCbor'. Nonminimal integers and indefinite arrays
-- are accepted; output encoding uses definite arrays and shortest integers.
decodeCbor :: ByteString -> Either Error UnitInterval
decodeCbor = Internal.decodeBytes Internal.decodeUnitInterval
