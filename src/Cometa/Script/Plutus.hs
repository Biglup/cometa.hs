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

-- | Versioned compiled Plutus scripts with exact byte identity. Compiled bytes
-- usually contain one CBOR bytestring around Flat code; script CBOR adds another
-- bytestring layer. Import never guesses or removes a layer. Raw-byte import
-- checks nonemptiness; CBOR import also checks outer framing. Neither checks
-- whether code is executable for its version.
--
-- @
-- import qualified Cometa.Script.Plutus as Plutus
-- import qualified Data.ByteString as ByteString
--
-- script = Plutus.fromBytes Plutus.V3 (ByteString.pack [0x45, 1, 0, 0, 0x24, 0x99])
-- @
module Cometa.Script.Plutus
  ( -- * Compiled scripts
    Version (..),
    PlutusScript,
    fromBytes,
    toBytes,
    version,

    -- * Script CBOR
    encodeCbor,
    decodeCbor,

    -- * Hashing and parameter application
    hash,
    applyParams,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import Cometa.Credential (ScriptHash)
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.FFI.Cbor as Buffer
import qualified Cometa.Internal.FFI.Script as Native
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (copyStaticText, withOwnedOutput)
import Cometa.PlutusData (PlutusData)
import qualified Cometa.PlutusData as PlutusData
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (castPtr, nullPtr)
import Foreign.Storable (poke)

-- TYPES ----------------------------------------------------------------------

-- | Ledger language version; ordering follows version number. Availability
-- depends on the ledger era; this type does not assert deployment support.
data Version = V1 | V2 | V3 | V4
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Nonempty immutable compiled bytes and their version, with the exact outer
-- script CBOR preserved on import. Equality compares version and outer encoding;
-- ordering is version first, then lexicographic encoding. 'Show' is diagnostic.
data PlutusScript = PlutusScript !Version !ByteString !ByteString
  deriving (Show)

instance Eq PlutusScript where
  left == right = version left == version right && encodeCbor left == encodeCbor right

instance Ord PlutusScript where
  compare left right = compare (version left, encodeCbor left) (version right, encodeCbor right)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import opaque compiled bytes without decoding or normalizing their contents.
-- Empty input returns 'EmptyPlutusScript'. Executability is checked only when a
-- VM operation such as 'applyParams' decodes the program.
fromBytes :: Version -> ByteString -> Either Error PlutusScript
fromBytes language bytes
  | ByteString.null bytes = Left EmptyPlutusScript
  | otherwise = Right (PlutusScript language bytes (Write.toStrictByteString (Encode.encodeBytes bytes)))

-- | Exact compiled bytes, excluding the outer script CBOR bytestring layer.
toBytes :: PlutusScript -> ByteString
toBytes (PlutusScript _ bytes _) = bytes

-- | The declared ledger language version.
version :: PlutusScript -> Version
version (PlutusScript language _ _) = language

-- | Encode the outer script bytestring. Imported encodings retain their exact
-- form, including nonminimal lengths and indefinite chunks. Compiled bytes are
-- never normalized by this operation.
encodeCbor :: PlutusScript -> ByteString
encodeCbor (PlutusScript _ _ encoded) = encoded

-- | Decode exactly one nonempty outer bytestring for the supplied version.
-- Malformed, trailing or schema-invalid input returns 'InvalidScriptCbor'; an
-- empty payload returns 'EmptyPlutusScript'. Both outer and compiled bytes retain
-- their identity; this operation does not decode executable Flat code.
decodeCbor :: Version -> ByteString -> Either Error PlutusScript
decodeCbor language encoded = case Read.deserialiseFromBytes decodeBytes (Lazy.fromStrict encoded) of
  Left failure -> Left (InvalidScriptCbor (Text.pack (show failure)))
  Right (trailing, bytes)
    | not (Lazy.null trailing) -> Left (InvalidScriptCbor "Trailing bytes after Plutus script")
    | ByteString.null bytes -> Left EmptyPlutusScript
    | otherwise -> Right (PlutusScript language bytes encoded)

-- | Compute BLAKE2b-224 over the version prefix (1 through 4) followed by exact
-- compiled bytes. The outer script encoding does not participate in the hash.
-- Native hashing failures return 'Cometa.Error.NativeError'.
hash :: PlutusScript -> IO (Either Error ScriptHash)
hash script = do
  result <- Blake2b.compute 28 (ByteString.cons (fromIntegral (fromEnum (version script) + 1)) (toBytes script))
  pure (result >>= Credential.scriptHashFromBytes . Blake2b.toBytes)

-- | Decode a single-CBOR-wrapped Flat program, apply data constants in list
-- order, and serialize a new program with the same declared language version.
-- The first parameter is the innermost application. Even an empty list invokes
-- the VM and can normalize a noncanonical program encoding. The original script
-- is unchanged. Malformed programs or native failures return 'NativeError'.
-- This operation checks program decoding, not ledger-era or language validity.
applyParams :: PlutusScript -> [PlutusData] -> IO (Either Error PlutusScript)
applyParams script parameters =
  ByteString.useAsCStringLen (toBytes script) $ \(code, codeSize) ->
    ByteString.useAsCStringLen (PlutusData.encodeCbor (PlutusData.List parameters)) $ \(params, paramsSize) ->
      allocaBytes 1024 $ \diagnostic -> do
        poke diagnostic 0
        result <-
          withOwnedOutput
            "script.applyParams"
            Buffer.cBufferUnref
            (\output -> Native.cApplyParams (castPtr code) (fromIntegral codeSize) (castPtr params) (fromIntegral paramsSize) output diagnostic 1024)
            copyBuffer
        case result of
          Right bytes -> pure (fromBytes (version script) bytes)
          Left failure@(NativeContractFailure _) -> pure (Left (fromNativeFailure failure))
          Left (NativeFailure operation status fallback) -> do
            message <- copyStaticText diagnostic
            pure (Left (fromNativeFailure (NativeFailure operation status (if Text.null message then fallback else message))))
  where
    -- Copy borrowed result storage before the scoped buffer is released; no
    -- native storage or arena-backed values survive this operation.
    copyBuffer buffer = do
      size <- Buffer.cBufferSize buffer
      bytes <- Buffer.cBufferData buffer
      if bytes == nullPtr || size == 0 || toInteger size > toInteger (maxBound :: Int)
        then pure (Left (NativeContractFailure "script.applyParams"))
        else Right <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)

decodeBytes :: Decode.Decoder s ByteString
decodeBytes = do
  token <- Decode.peekTokenType
  if token == Decode.TypeBytesIndef
    then do
      Decode.decodeBytesIndef
      loop []
    else Decode.decodeBytes
  where
    loop accumulated = do
      ended <- Decode.decodeBreakOr
      if ended
        then pure (ByteString.concat (reverse accumulated))
        else do
          chunk <- Decode.decodeBytes
          loop (chunk : accumulated)
