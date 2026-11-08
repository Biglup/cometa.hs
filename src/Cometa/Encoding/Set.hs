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

-- | CBOR representation of ledger set collections. This choice controls the
-- optional tag only; ordering and duplicate handling belong to each collection.
module Cometa.Encoding.Set (SetEncoding (..)) where

-- TYPES ----------------------------------------------------------------------

-- | Whether a set array carries CBOR tag 258. Choose the representation required
-- by the target protocol; accepting both when decoding does not imply both are
-- valid on every network or protocol version.
data SetEncoding
  = -- | Prefix the array with CBOR tag 258.
    TaggedSet
  | -- | Encode the array without a set tag.
    UntaggedSet
  deriving (Eq, Ord, Show, Enum, Bounded)
