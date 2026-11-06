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

-- | Ordered certificate collections. Order and duplicate certificates are
-- retained. An exact envelope preserves imported tagging and integer encodings.
--
-- @
-- import qualified Cometa.Certificate.Collection as Certificates
--
-- noCertificates :: Certificates.Certificates
-- noCertificates = Certificates.empty
-- @
module Cometa.Certificate.Collection
  ( Certificates,
    empty,
    fromList,
    toList,
    encodeCbor,
    EncodedCertificates,
    decodeCbor,
    fromCertificates,
    toCertificates,
    toCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Certificate (Certificate)
import Cometa.Error (Error)
import Cometa.Internal.Certificate (Certificates (..), EncodedCertificates, fromCertificates, toCertificates)
import qualified Cometa.Internal.Certificate as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | No certificates.
empty :: Certificates
empty = Certificates []

-- | Assemble certificates in transaction order, preserving duplicates.
fromList :: [Certificate] -> Certificates
fromList = Certificates

-- | Certificates in their original order, including duplicates.
toList :: Certificates -> [Certificate]
toList (Certificates values) = values

-- | Fresh definite array with set tag 258, preserving order and duplicates.
encodeCbor :: Certificates -> ByteString
encodeCbor = Internal.encodeCertificates

-- | Validate a complete certificate array with an optional set tag 258.
-- Definite and indefinite arrays are accepted. Certificates obey the checks in
-- 'Cometa.Certificate.decodeCbor'. Invalid input and trailing bytes return
-- 'Cometa.Error.InvalidCertificateCbor'. Exact bytes, including tag absence, remain
-- available through 'toCbor'.
decodeCbor :: ByteString -> Either Error EncodedCertificates
decodeCbor = Internal.decodeCertificates

-- | Return the exact imported or freshly assembled encoding.
toCbor :: EncodedCertificates -> ByteString
toCbor = Internal.certificatesCbor
