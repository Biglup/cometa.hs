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

-- | Stake-pool relays with validated network-order addresses and DNS text.
-- Ports and addresses may legitimately be absent.
--
-- @SingleHostAddress Nothing Nothing Nothing@ represents an unspecified relay.
module Cometa.Pool.Relay
  ( Ipv4,
    ipv4FromBytes,
    ipv4Bytes,
    ipv4FromText,
    ipv4Text,
    Ipv6,
    ipv6FromBytes,
    ipv6Bytes,
    ipv6FromText,
    ipv6Text,
    DnsName,
    mkDnsName,
    dnsNameText,
    Relay (..),
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Internal.Pool
  ( DnsName,
    Ipv4,
    Ipv6,
    Relay (..),
    dnsNameText,
    ipv4Bytes,
    ipv4FromBytes,
    ipv4FromText,
    ipv4Text,
    ipv6Bytes,
    ipv6FromBytes,
    ipv6FromText,
    ipv6Text,
    mkDnsName,
  )
import qualified Cometa.Internal.Pool as Internal
import Data.ByteString (ByteString)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite CBOR with shortest integer encodings.
-- Re-encoding semantic data may change transaction identity.
encodeCbor :: Relay -> ByteString
encodeCbor = Internal.encode Internal.relayEncoding

-- | Decode the complete value. Definite or indefinite arrays and
-- nonminimal unsigned integers are accepted. All field bounds, arities, UTF-8
-- and trailing bytes are checked; violations return
-- 'Cometa.Error.InvalidPoolCbor'. The original encoding is not retained.
decodeCbor :: ByteString -> Either Error Relay
decodeCbor = Internal.decodeComplete Internal.relayDecoder
