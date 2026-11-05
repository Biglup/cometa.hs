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

-- | Exact lovelace prices per memory unit and CPU step.
-- Prices may exceed one lovelace. Serialization places memory before steps.
--
-- @ExUnitPrices price price@ assembles prices from validated fractions.
module Cometa.Protocol.ExUnitPrices
  ( ExUnitPrices (..),
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.ProtocolValues (ExUnitPrices (..))
import qualified Cometa.Internal.ProtocolValues as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode a definite-length ledger CBOR value with shortest integer encodings.
encodeCbor :: ExUnitPrices -> ByteString
encodeCbor = Internal.encodeBytes Internal.encodeExUnitPrices

-- | Decode exactly one ledger CBOR value. Invalid fields or trailing data return
-- 'Cometa.Error.InvalidProtocolCbor'. Nonminimal integers and indefinite arrays
-- are accepted; output encoding uses definite arrays and shortest integers.
decodeCbor :: ByteString -> Either Error ExUnitPrices
decodeCbor = Internal.decodeBytes Internal.decodeExUnitPrices
