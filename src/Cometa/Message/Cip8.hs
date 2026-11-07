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

-- | CIP-8 message signing with an address or key-hash binding. Payloads are
-- nonempty raw bytes, signed directly with @hashed = false@ and empty external
-- AAD. Detached payloads, prehashing and custom AAD are not supported by this API.
--
-- Signing records the supplied binding; it does not prove the key controls that
-- address or matches that hash. Applications and verifiers must check that link.
-- The result owns immutable public bytes and remains usable after the key closes.
module Cometa.Message.Cip8
  ( Binding,
    addressBinding,
    keyHashBinding,
    SignedMessage (..),
    sign,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.Message.Cip8
  ( Binding,
    SignedMessage (..),
    addressBinding,
    keyHashBinding,
    sign,
  )
