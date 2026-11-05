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

-- | Off-chain governance metadata locations and hashes. Validate external text
-- and bytes once, then assemble 'Anchor' values with its total constructor.
-- Locations are not fetched or checked for URI syntax.
--
-- @
-- import qualified Cometa.Governance.Anchor as Anchor
--
-- attach :: Anchor.Url -> Anchor.DataHash -> Anchor.Anchor
-- attach = Anchor.Anchor
-- @
module Cometa.Governance.Anchor
  ( Url,
    mkUrl,
    urlText,
    DataHash,
    dataHashFromBytes,
    dataHashBytes,
    hashData,
    Anchor (..),
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error)
import Cometa.Internal.Governance (Anchor (..), DataHash, Url, dataHashBytes, dataHashFromBytes, mkUrl, urlText)
import qualified Cometa.Internal.Governance as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Hash the exact off-chain payload with BLAKE2b-256. Empty input returns
-- 'Cometa.Error.NativeError' with the native out-of-bounds-memory-read code,
-- matching the BLAKE2b boundary. Native allocation or hashing failures also return
-- 'Cometa.Error.NativeError'. No JSON parsing or normalization occurs.
hashData :: ByteString -> IO (Either Error DataHash)
hashData bytes = do
  result <- Blake2b.compute 32 bytes
  pure (result >>= dataHashFromBytes . Blake2b.toBytes)

-- | Fresh definite CBOR @[URL text, hash bytes]@. Re-encoding imported semantic
-- data may change its containing transaction's encoding; preserve the original
-- enclosing CBOR when identity matters.
encodeCbor :: Anchor -> ByteString
encodeCbor = Internal.encodeAnchor

-- | Decode one complete anchor, accepting definite or indefinite arrays and
-- nonminimal lengths. URL validation, the exact 32-byte hash and array arity
-- are enforced; invalid input or trailing bytes returns
-- 'Cometa.Error.InvalidGovernanceCbor'. This returns semantic data, not an
-- encoding-preserving wrapper.
decodeCbor :: ByteString -> Either Error Anchor
decodeCbor = Internal.decodeAnchor
