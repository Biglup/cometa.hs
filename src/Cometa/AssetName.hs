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

-- | Validated native-asset names, containing zero through 32 arbitrary bytes.
-- Names identify assets by bytes; UTF-8 is an optional interpretation.
--
-- @
-- import qualified Cometa.AssetName as AssetName
--
-- roundTrip :: AssetName.AssetName -> Bool
-- roundTrip name = AssetName.fromBytes (AssetName.toBytes name) == Right name
-- @
module Cometa.AssetName
  ( AssetName,
    empty,
    fromBytes,
    toBytes,
    fromHex,
    toHex,
    fromText,
    toText,
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.Internal.TransactionCbor as Cbor
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text

-- TYPES ----------------------------------------------------------------------

-- | Zero through 32 bytes. Equality and ordering compare exact bytes
-- lexicographically. 'Show' is diagnostic output.
newtype AssetName = AssetName ByteString deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | The empty native-asset name, distinct from the Ada asset.
empty :: AssetName
empty = AssetName ByteString.empty

-- | Import arbitrary bytes, including NUL and invalid UTF-8. More than 32 bytes
-- returns 'InvalidAssetNameLength' with the actual byte count.
fromBytes :: ByteString -> Either Error AssetName
fromBytes bytes
  | ByteString.length bytes > 32 = Left (InvalidAssetNameLength (ByteString.length bytes))
  | otherwise = Right (AssetName bytes)

-- | Exact name bytes.
toBytes :: AssetName -> ByteString
toBytes (AssetName bytes) = bytes

-- | Import zero through 64 ASCII hexadecimal digits, accepting either case.
-- Odd lengths, prefixes, whitespace and nonhexadecimal characters return
-- 'InvalidHex'; decoded names longer than 32 bytes return 'InvalidAssetNameLength'.
fromHex :: Text -> Either Error AssetName
fromHex text = maybe (Left InvalidHex) fromBytes (Hex.decodeHex text)

-- | Lowercase hexadecimal without a prefix. The empty name renders as empty text.
toHex :: AssetName -> Text
toHex = Hex.encodeHex . toBytes

-- | Encode text as UTF-8, then validate the 32-byte bound. The limit counts
-- encoded bytes, not characters. No Unicode normalization is performed.
fromText :: Text -> Either Error AssetName
fromText = fromBytes . Text.encodeUtf8

-- | Interpret exact bytes as UTF-8. Invalid UTF-8 returns 'Nothing'; no bytes
-- are replaced or discarded. An empty name returns @Just ""@.
toText :: AssetName -> Maybe Text
toText name = either (const Nothing) Just (Text.decodeUtf8' (toBytes name))

-- | Encode the exact name bytes as a shortest-length definite CBOR byte string.
encodeCbor :: AssetName -> ByteString
encodeCbor = Cbor.encode . E.encodeBytes . toBytes

-- | Decode exactly one CBOR byte string containing 0 through 32 bytes.
-- Nonminimal length encodings are accepted; invalid schemas, lengths or
-- trailing bytes return 'InvalidAssetNameCbor'. Fresh encoding is semantic
-- and does not retain the original CBOR representation.
decodeCbor :: ByteString -> Either Error AssetName
decodeCbor = Cbor.decodeAs InvalidAssetNameCbor (D.decodeBytes >>= either (fail . show) pure . fromBytes)
