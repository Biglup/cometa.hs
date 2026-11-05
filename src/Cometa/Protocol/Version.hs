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

-- | Ledger protocol versions with unsigned 64-bit major and 32-bit minor numbers.
--
-- @ProtocolVersion 9 0@ represents protocol version 9.0.
module Cometa.Protocol.Version
  ( ProtocolVersion (..),
    mkProtocolVersion,
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.ProtocolValues (ProtocolVersion (..), mkProtocolVersion)
import qualified Cometa.Internal.ProtocolValues as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode a definite-length ledger CBOR value with shortest integer encodings.
encodeCbor :: ProtocolVersion -> ByteString
encodeCbor = Internal.encodeBytes Internal.encodeProtocolVersion

-- | Decode exactly one ledger CBOR value. Invalid fields or trailing data return
-- 'Cometa.Error.InvalidProtocolCbor'. Nonminimal integers and indefinite arrays
-- are accepted; output encoding uses definite arrays and shortest integers.
decodeCbor :: ByteString -> Either Error ProtocolVersion
decodeCbor = Internal.decodeBytes Internal.decodeProtocolVersion
