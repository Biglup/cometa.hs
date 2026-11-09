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

-- | Strict hexadecimal conversion for raw bytes. Decode a textual payload,
-- then pass the bytes to the domain's ordinary validator. Hexadecimal syntax
-- does not establish a script, hash role, CBOR schema or ledger validity.
--
-- @
-- import qualified Cometa.Encoding.Hex as Hex
-- import qualified Cometa.Script.Plutus as Plutus
--
-- readScript text = Hex.decode text >>= Plutus.fromBytes Plutus.V3
-- @
module Cometa.Encoding.Hex (encode, decode) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (InvalidHex))
import qualified Cometa.Internal.Hex as Internal
import Data.ByteString (ByteString)
import Data.Text (Text)

-- DEFINITIONS ----------------------------------------------------------------

-- | Render every byte as two lowercase ASCII hexadecimal digits, without a
-- prefix or whitespace. Empty bytes produce empty text. For all byte strings,
-- @decode (encode bytes) == Right bytes@.
encode :: ByteString -> Text
encode = Internal.encodeHex

-- | Decode a complete even-length sequence of ASCII hexadecimal digits,
-- accepting either letter case. Empty text produces empty bytes. Odd length,
-- non-ASCII characters, whitespace, prefixes and embedded NUL characters return
-- 'InvalidHex'; no partial payload is returned. A successful result still needs
-- validation by the intended domain decoder.
decode :: Text -> Either Error ByteString
decode = maybe (Left InvalidHex) Right . Internal.decodeHex
