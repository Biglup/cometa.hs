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
{-# LANGUAGE OverloadedStrings #-}

-- | Inspect transaction fields as JSON domain values. These named operations
-- use the native CIP-116 representation, including its governance and nested
-- transaction fields. Large protocol integers use decimal strings; binary data
-- uses text encodings, and mapping fields may use ordered key/value arrays.
-- JSON object key order is not significant.
--
-- Inspection leaves transaction bytes, hashes and signatures unchanged. The
-- result describes fields; it is not a transaction serialization for signing,
-- an exact-CBOR interchange format, or a check of ledger validity. Use
-- 'Data.Aeson.encode' to render the returned value.
--
-- @
-- inspected <- Inspection.transaction transaction
-- -- fmap Data.Aeson.encode inspected
-- @
module Cometa.Transaction.Inspection
  ( transaction,
    subTransaction,
    body,
    subBody,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import qualified Cometa.Internal.Inspection as Inspection
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import Data.Aeson (Value)

-- DEFINITIONS ----------------------------------------------------------------

-- | Inspect the complete body, validity flag, witnesses and optional auxiliary
-- data. Native errors remain explicit; no network queries or signing occur.
transaction :: Tx.Transaction -> IO (Either Error Value)
transaction = Inspection.inspect "inspection.transaction" 0 . Tx.encodeCbor

-- | Inspect a subtransaction's body, witnesses and optional auxiliary data.
-- No fee or outer transaction validity flag is added to the result.
subTransaction :: Sub.SubTransaction -> IO (Either Error Value)
subTransaction = Inspection.inspect "inspection.subTransaction" 1 . Sub.encodeCbor

-- | Inspect an exact encoded top-level body, including any nested transactions.
body :: Body.EncodedBody -> IO (Either Error Value)
body = Inspection.inspect "inspection.body" 2 . Body.toCbor

-- | Inspect an exact encoded subtransaction body using its local field schema.
subBody :: SubBody.EncodedBody -> IO (Either Error Value)
subBody = Inspection.inspect "inspection.subBody" 3 . SubBody.toCbor
