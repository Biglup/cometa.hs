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

-- | Exact nonnegative protocol fractions, with positive denominators.
-- Numerators and denominators are unsigned 64-bit values. Input pairs remain
-- unreduced for serialization; equality and ordering compare numeric values.
--
-- @mkNonNegativeRational 577 10000@ constructs an exact execution price.
module Cometa.Protocol.Rational
  ( NonNegativeRational,
    mkNonNegativeRational,
    numerator,
    denominator,
    toRational,
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.ProtocolValues (NonNegativeRational, mkNonNegativeRational)
import qualified Cometa.Internal.ProtocolValues as Internal
import Data.ByteString (ByteString)
import Data.Word (Word64)
import Prelude hiding (toRational)

-- DEFINITIONS ----------------------------------------------------------------

-- | Original numerator, without fraction reduction.
numerator :: NonNegativeRational -> Word64
numerator = Internal.rationalNumerator

-- | Original positive denominator, without fraction reduction.
denominator :: NonNegativeRational -> Word64
denominator = Internal.rationalDenominator

-- | Exact numeric value, reduced by the standard Rational representation.
toRational :: NonNegativeRational -> Rational
toRational = Internal.rationalValue

-- | Encode a definite-length ledger CBOR value with shortest integer encodings.
encodeCbor :: NonNegativeRational -> ByteString
encodeCbor = Internal.encodeBytes Internal.encodeRational

-- | Decode exactly one ledger CBOR value. Invalid fields or trailing data return
-- 'Cometa.Error.InvalidProtocolCbor'. Nonminimal integers and indefinite arrays
-- are accepted; output encoding uses definite arrays and shortest integers.
decodeCbor :: ByteString -> Either Error NonNegativeRational
decodeCbor = Internal.decodeBytes Internal.decodeRational
