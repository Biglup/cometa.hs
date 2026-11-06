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

-- | Stake-pool BLS public keys and proofs of possession. Validation checks
-- byte lengths only; it does not authenticate the key or verify its proof.
--
-- @mkBlsKey publicKey proof@ validates 96 key bytes and 48 proof bytes.
module Cometa.Pool.BlsKey
  ( BlsKey,
    mkBlsKey,
    publicKeyBytes,
    possessionProofBytes,
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.Pool (BlsKey, mkBlsKey, possessionProofBytes, publicKeyBytes)
import qualified Cometa.Internal.Pool as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite CBOR with shortest integer encodings.
-- Re-encoding semantic data may change transaction identity.
encodeCbor :: BlsKey -> ByteString
encodeCbor = Internal.encode Internal.blsEncoding

-- | Decode the complete value. Definite or indefinite arrays and
-- nonminimal unsigned integers are accepted. All field bounds, arities, UTF-8
-- and trailing bytes are checked; violations return
-- 'Cometa.Error.InvalidPoolCbor'. The original encoding is not retained.
decodeCbor :: ByteString -> Either Error BlsKey
decodeCbor = Internal.decodeComplete Internal.blsDecoder
