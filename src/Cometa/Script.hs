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

-- | Native and versioned Plutus script alternatives. The combined CBOR form is
-- @[language, payload]@, where native is zero and Plutus versions are 1 through 4.
-- The envelope is normalized on encoding; each payload retains its exact bytes,
-- which determine script identity and hashing.
--
-- @
-- import qualified Cometa.Script as Script
-- import qualified Cometa.Script.Native as Native
--
-- script :: Script.Script
-- script = Script.Native (Native.allOf [])
-- @
module Cometa.Script
  ( Script (..),
    encodeCbor,
    decodeCbor,
    hash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import Codec.CBOR.Term (decodeTerm)
import qualified Codec.CBOR.Write as Write
import Cometa.Credential (ScriptHash)
import Cometa.Error (Error (..))
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text

-- TYPES ----------------------------------------------------------------------

-- | Script alternatives with Haskell-owned payloads. Equality and ordering
-- compare the alternative then its payload representation; native comes first.
data Script
  = -- | A signature/time/guard native script.
    Native !Native.NativeScript
  | -- | A compiled Plutus script carrying its language version.
    Plutus !Plutus.PlutusScript
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode a definite two-element array and minimal language tag, preserving the
-- payload's exact encoding. Nonminimal imported envelopes normalize on encoding;
-- they do not contribute to the script hash.
encodeCbor :: Script -> ByteString
encodeCbor script = Write.toStrictByteString (Encode.encodeListLen 2 <> payload)
  where
    payload = case script of
      Native native -> Encode.encodeWord 0 <> Encode.encodePreEncoded (Native.encodeCbor native)
      Plutus plutus -> Encode.encodeWord (fromIntegral (fromEnum (Plutus.version plutus) + 1)) <> Encode.encodePreEncoded (Plutus.encodeCbor plutus)

-- | Decode exactly one two-element native/Plutus envelope. Unknown language tags,
-- incorrect arity, malformed payloads and trailing bytes return
-- 'InvalidScriptCbor'. Payload validators also retain their documented errors.
-- The envelope's encoding is not retained; the payload's encoding is exact.
decodeCbor :: ByteString -> Either Error Script
decodeCbor bytes = case Read.deserialiseFromBytes decodeEnvelope (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidScriptCbor (Text.pack (show failure)))
  Right (trailing, (language, payload))
    | not (Lazy.null trailing) -> Left (InvalidScriptCbor "Trailing bytes after script envelope")
    | otherwise -> case language of
        0 -> Native <$> Native.decodeCbor payload
        1 -> Plutus <$> Plutus.decodeCbor Plutus.V1 payload
        2 -> Plutus <$> Plutus.decodeCbor Plutus.V2 payload
        3 -> Plutus <$> Plutus.decodeCbor Plutus.V3 payload
        4 -> Plutus <$> Plutus.decodeCbor Plutus.V4 payload
        _ -> Left (InvalidScriptCbor "Unknown script language")
  where
    decodeEnvelope = do
      size <- Decode.decodeListLenOrIndef
      unless (maybe True (== 2) size) (fail "Invalid script envelope arity")
      language <- Decode.decodeWord
      (_, start, end) <- Decode.decodeWithByteSpan decodeTerm
      case size of
        Just _ -> pure ()
        Nothing -> do
          ended <- Decode.decodeBreakOr
          unless ended (fail "Unexpected script envelope field")
      let payload = ByteString.take (fromIntegral (end - start)) (ByteString.drop (fromIntegral start) bytes)
      pure (language, payload)

-- | Hash using the native prefix zero or the declared Plutus version prefix.
-- The combined envelope is excluded. Native failures return 'Cometa.Error.NativeError'.
hash :: Script -> IO (Either Error ScriptHash)
hash script = case script of
  Native native -> Native.hash native
  Plutus plutus -> Plutus.hash plutus
