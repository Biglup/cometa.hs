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

-- | Typed stake-pool registration parameters. Validate hashes, relays,
-- metadata and margin once, then assemble or update the record without effects.
--
-- @parameters { metadata = Nothing }@ removes an optional metadata reference.
module Cometa.Pool.Parameters
  ( PoolParameters (..),
    VrfKeyHash,
    vrfKeyHashFromBytes,
    vrfKeyHashBytes,
    encodeCbor,
    encodeCborWith,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Encoding.Set (SetEncoding)
import Cometa.Error (Error)
import Cometa.Internal.Pool (PoolParameters (..), VrfKeyHash, vrfKeyHashBytes, vrfKeyHashFromBytes)
import qualified Cometa.Internal.Pool as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite CBOR array containing the nine pool fields, or ten when
-- a BLS key is present after the VRF hash. Owners are sorted and tagged 258;
-- relay order and duplicates remain. Re-encoding semantic data may change
-- transaction identity.
encodeCbor :: PoolParameters -> ByteString
encodeCbor = Internal.encode Internal.parametersValueEncoding

-- | Fresh definite parameters with the requested tag on the sorted owner set.
-- Other fields use their usual encoding. This re-encodes semantic data; it is
-- not an edit to an imported transaction's exact bytes.
encodeCborWith :: SetEncoding -> PoolParameters -> ByteString
encodeCborWith requested = Internal.encode (Internal.parametersValueEncodingWith requested)

-- | Decode the complete array. Definite or indefinite arrays and
-- nonminimal unsigned integers are accepted. All field bounds, arities, UTF-8
-- and trailing bytes are checked; violations return
-- 'Cometa.Error.InvalidPoolCbor'. The original encoding is not retained.
-- Duplicate owners are rejected; untagged owner sets are accepted.
-- A null BLS placeholder is accepted and omitted on re-encoding.
decodeCbor :: ByteString -> Either Error PoolParameters
decodeCbor = Internal.decodeComplete Internal.parametersValueDecoder
