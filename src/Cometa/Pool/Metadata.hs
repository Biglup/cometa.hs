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

-- | Off-chain stake-pool metadata references. Locations are not fetched.
-- Validate external input once, then assemble with the total constructor.
--
-- @Metadata location digest@ associates a location with its expected hash.
module Cometa.Pool.Metadata
  ( Url,
    mkUrl,
    urlText,
    MetadataHash,
    metadataHashFromBytes,
    metadataHashBytes,
    Metadata (..),
    hashData,
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error)
import Cometa.Internal.Pool (Metadata (..), MetadataHash, Url, metadataHashBytes, metadataHashFromBytes, mkUrl, urlText)
import qualified Cometa.Internal.Pool as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite CBOR with shortest integer encodings.
-- Re-encoding semantic data may change transaction identity.
encodeCbor :: Metadata -> ByteString
encodeCbor = Internal.encode Internal.metadataEncoding

-- | Decode the complete value. Definite or indefinite arrays and
-- nonminimal unsigned integers are accepted. All field bounds, arities, UTF-8
-- and trailing bytes are checked; violations return
-- 'Cometa.Error.InvalidPoolCbor'. The original encoding is not retained.
decodeCbor :: ByteString -> Either Error Metadata
decodeCbor = Internal.decodeComplete Internal.metadataDecoder

-- | Compute the BLAKE2b-256 digest of the exact metadata payload bytes. No
-- JSON parsing or normalization occurs. Empty input or native hashing failures
-- return 'Cometa.Error.NativeError', following the BLAKE2b boundary.
hashData :: ByteString -> IO (Either Error MetadataHash)
hashData bytes = do
  result <- Blake2b.compute 32 bytes
  pure (result >>= metadataHashFromBytes . Blake2b.toBytes)
