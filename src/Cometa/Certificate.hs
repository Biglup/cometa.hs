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

-- | Assemble standalone staking and governance certificates from validated
-- credentials, delegation targets, pool parameters and optional anchors.
-- Deposits and refunds are explicit lovelace; protocol and era checks belong to
-- the transaction workflow. Fresh encoding may change imported transaction bytes.
--
-- @
-- import qualified Cometa.Certificate as Certificate
-- import qualified Cometa.Credential as Credential
-- import qualified Cometa.Governance.DRep as DRep
--
-- abstain :: Credential.Credential Credential.Stake -> Certificate.Certificate
-- abstain stake = Certificate.VoteDelegation stake DRep.AlwaysAbstain
-- @
module Cometa.Certificate
  ( Certificate (..),
    Mir (..),
    Pot (..),
    encodeCbor,
    EncodedCertificate,
    decodeCbor,
    fromCertificate,
    toCertificate,
    toCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.Certificate (Certificate (..), EncodedCertificate, Mir (..), Pot (..), fromCertificate, toCertificate)
import qualified Cometa.Internal.Certificate as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode semantic data as fresh definite CBOR with minimal unsigned integers.
-- Reward credentials are sorted by kind and hash. No ledger validation occurs.
encodeCbor :: Certificate -> ByteString
encodeCbor = Internal.encodeCertificate

-- | Validate one complete certificate and retain its exact CBOR. Accepts definite
-- and indefinite arrays, nonminimal integers, and all certificate kinds 0–18.
-- Credential/hash lengths, arity and unsigned 64-bit bounds are checked. MIR
-- signed amounts and duplicate reward credentials are rejected. Malformed input
-- or trailing bytes returns 'Cometa.Error.InvalidCertificateCbor'.
decodeCbor :: ByteString -> Either Error EncodedCertificate
decodeCbor = Internal.decodeCertificate

-- | Exact imported bytes, or fresh bytes for values built with 'fromCertificate'.
-- Use this when imported certificate encoding must remain unchanged.
toCbor :: EncodedCertificate -> ByteString
toCbor = Internal.certificateCbor
