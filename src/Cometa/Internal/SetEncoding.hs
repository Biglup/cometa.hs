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

-- | Tag edits on already validated ledger set encodings.
module Cometa.Internal.SetEncoding (encoding, withEncoding) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Encoding.Set (SetEncoding (..))
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B

-- FUNCTIONS ------------------------------------------------------------------

-- | Observe the outer tag of a validated set array.
encoding :: ByteString -> SetEncoding
encoding bytes = case B.uncons bytes of
  Just (header, _) | header .&. 224 == 192 -> TaggedSet
  _ -> UntaggedSet

-- | Preserve an unchanged representation exactly. Changed tags retain every byte
-- of the array, including indefinite lengths and nonminimal element encodings.
-- The input must already be validated as an array optionally prefixed by tag 258.
withEncoding :: SetEncoding -> ByteString -> ByteString
withEncoding requested bytes
  | requested == encoding bytes = bytes
  | requested == TaggedSet = B.pack [217, 1, 2] <> bytes
  | otherwise = B.drop (tagWidth bytes) bytes

-- | Header width of a validated tag 258, including nonminimal integer widths.
tagWidth :: ByteString -> Int
tagWidth bytes = case B.uncons bytes of
  Just (header, _) -> case header .&. 31 of
    25 -> 3
    26 -> 5
    27 -> 9
    _ -> 0
  Nothing -> 0
