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
{-# LANGUAGE TupleSections #-}

-- | Transaction metadata and auxiliary scripts. Fresh assembly uses the tagged
-- Alonzo map. Imported Shelley metadata, Shelley-MA arrays and tagged maps retain
-- their full exact bytes, which determine the auxiliary-data hash.
-- @fromAuxiliaryData empty@ assembles an empty tagged auxiliary map.
module Cometa.Transaction.AuxiliaryData
  ( AuxiliaryData,
    auxiliaryData,
    metadata,
    nativeScripts,
    plutusV1Scripts,
    plutusV2Scripts,
    plutusV3Scripts,
    plutusV4Scripts,
    empty,
    EncodedAuxiliaryData,
    encodeCbor,
    decodeCbor,
    fromAuxiliaryData,
    toAuxiliaryData,
    toCbor,
    AuxiliaryDataHash,
    hash,
    hashFromBytes,
    hashBytes,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as C
import qualified Cometa.Metadata as Metadata
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (catMaybes)

-- TYPES ----------------------------------------------------------------------

-- | Optional field presence is preserved, including present empty lists.
-- Script lists retain order and duplicates. Metadata retains its exact nested CBOR.
data AuxiliaryData = AuxiliaryData
  { auxiliaryMetadata :: !(Maybe Metadata.EncodedMetadata),
    auxiliaryNativeScripts :: !(Maybe [Native.NativeScript]),
    auxiliaryPlutusV1Scripts :: !(Maybe [Plutus.PlutusScript]),
    auxiliaryPlutusV2Scripts :: !(Maybe [Plutus.PlutusScript]),
    auxiliaryPlutusV3Scripts :: !(Maybe [Plutus.PlutusScript]),
    auxiliaryPlutusV4Scripts :: !(Maybe [Plutus.PlutusScript])
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Optional metadata with its exact nested encoding.
metadata :: AuxiliaryData -> Maybe Metadata.EncodedMetadata
metadata = auxiliaryMetadata

-- | Optional ordered auxiliary native scripts, including duplicates.
nativeScripts :: AuxiliaryData -> Maybe [Native.NativeScript]
nativeScripts = auxiliaryNativeScripts

-- | Optional ordered auxiliary Plutus V1 scripts, including duplicates.
plutusV1Scripts :: AuxiliaryData -> Maybe [Plutus.PlutusScript]
plutusV1Scripts = auxiliaryPlutusV1Scripts

-- | Optional ordered auxiliary Plutus V2 scripts, including duplicates.
plutusV2Scripts :: AuxiliaryData -> Maybe [Plutus.PlutusScript]
plutusV2Scripts = auxiliaryPlutusV2Scripts

-- | Optional ordered auxiliary Plutus V3 scripts, including duplicates.
plutusV3Scripts :: AuxiliaryData -> Maybe [Plutus.PlutusScript]
plutusV3Scripts = auxiliaryPlutusV3Scripts

-- | Optional ordered auxiliary Plutus V4 scripts, including duplicates.
plutusV4Scripts :: AuxiliaryData -> Maybe [Plutus.PlutusScript]
plutusV4Scripts = auxiliaryPlutusV4Scripts

-- | Assemble metadata, optional native scripts and versioned Plutus scripts.
-- Plutus scripts are grouped by their validated version, retaining relative
-- order and duplicates within each version. Empty version groups are absent.
auxiliaryData :: Maybe Metadata.EncodedMetadata -> Maybe [Native.NativeScript] -> [Plutus.PlutusScript] -> AuxiliaryData
auxiliaryData meta natives scripts = AuxiliaryData meta natives (group Plutus.V1) (group Plutus.V2) (group Plutus.V3) (group Plutus.V4)
  where
    group version = case filter ((== version) . Plutus.version) scripts of
      [] -> Nothing
      values -> Just values

-- | All fields absent.
empty :: AuxiliaryData
empty = AuxiliaryData Nothing Nothing Nothing Nothing Nothing Nothing

-- | An auxiliary value and its full original bytes. Equality and ordering compare
-- bytes, so semantically equal encodings can have distinct hash identities.
data EncodedAuxiliaryData = EncodedAuxiliaryData !ByteString !AuxiliaryData deriving (Show)

instance Eq EncodedAuxiliaryData where
  a == b = toCbor a == toCbor b

instance Ord EncodedAuxiliaryData where
  compare a b = compare (toCbor a) (toCbor b)

-- | Fresh tagged map, preserving nested metadata and script encodings.
encodeCbor :: AuxiliaryData -> ByteString
encodeCbor value = C.encode (E.encodeTag 259 <> E.encodeMapLen (fromIntegral (length fields)) <> foldMap (uncurry (<>)) fields)
  where
    fields =
      catMaybes
        [ field 0 (C.raw . Metadata.toCbor <$> auxiliaryMetadata value),
          field 1 (listEncoding Native.encodeCbor <$> auxiliaryNativeScripts value),
          field 2 (listEncoding Plutus.encodeCbor <$> auxiliaryPlutusV1Scripts value),
          field 3 (listEncoding Plutus.encodeCbor <$> auxiliaryPlutusV2Scripts value),
          field 4 (listEncoding Plutus.encodeCbor <$> auxiliaryPlutusV3Scripts value),
          field 5 (listEncoding Plutus.encodeCbor <$> auxiliaryPlutusV4Scripts value)
        ]
    field key = fmap (E.encodeWord key,)

listEncoding :: (a -> ByteString) -> [a] -> E.Encoding
listEncoding encoder values = E.encodeListLen (fromIntegral (length values)) <> foldMap (C.raw . encoder) values

-- | Encode a newly assembled value and retain those bytes.
fromAuxiliaryData :: AuxiliaryData -> EncodedAuxiliaryData
fromAuxiliaryData value = EncodedAuxiliaryData (encodeCbor value) value

-- | Observe semantic fields.
toAuxiliaryData :: EncodedAuxiliaryData -> AuxiliaryData
toAuxiliaryData (EncodedAuxiliaryData _ value) = value

-- | Full original auxiliary CBOR, suitable for hashing.
toCbor :: EncodedAuxiliaryData -> ByteString
toCbor (EncodedAuxiliaryData bytes _) = bytes

-- | Decode historical metadata maps, metadata/script arrays, or tag-259 maps.
-- Unknown/duplicate fields, malformed scripts and trailing bytes fail.
decodeCbor :: ByteString -> Either Error EncodedAuxiliaryData
decodeCbor input = EncodedAuxiliaryData input <$> C.decodeAs InvalidAuxiliaryDataCbor parser input
  where
    parser = do
      token <- D.peekTokenType
      case token of
        D.TypeTag -> do
          tag <- D.decodeTag
          unless (tag == 259) (fail "Expected auxiliary tag 259")
          fields <- C.entries ((,) <$> D.decodeWord <*> C.slice input)
          unless (length fields == length (unique (map fst fields))) (fail "Duplicate auxiliary field")
          foldFields fields empty
        D.TypeMapLen -> historicalMetadata
        D.TypeMapLenIndef -> historicalMetadata
        _ -> do
          size <- D.decodeListLenOrIndef
          case size of
            Just 1 -> (\m -> empty {auxiliaryMetadata = Just m}) <$> C.nested input Metadata.decodeCbor
            Just 2 -> (AuxiliaryData . Just <$> C.nested input Metadata.decodeCbor) <*> (Just <$> C.list (C.nested input Native.decodeCbor)) <*> pure Nothing <*> pure Nothing <*> pure Nothing <*> pure Nothing
            Nothing -> do
              meta <- C.nested input Metadata.decodeCbor
              ended <- D.decodeBreakOr
              if ended
                then pure empty {auxiliaryMetadata = Just meta}
                else do
                  natives <- C.list (C.nested input Native.decodeCbor)
                  finished <- D.decodeBreakOr
                  unless finished (fail "Extra historical auxiliary fields")
                  pure empty {auxiliaryMetadata = Just meta, auxiliaryNativeScripts = Just natives}
            _ -> fail "Historical auxiliary array must contain one or two fields"
    historicalMetadata = (\m -> empty {auxiliaryMetadata = Just m}) <$> C.nested input Metadata.decodeCbor
    foldFields [] value = pure value
    foldFields ((key, bytes) : rest) value = do
      next <- case key of
        0 -> (\m -> value {auxiliaryMetadata = Just m}) <$> parsed Metadata.decodeCbor bytes
        1 -> (\s -> value {auxiliaryNativeScripts = Just s}) <$> parsed (scriptList Native.decodeCbor) bytes
        2 -> (\s -> value {auxiliaryPlutusV1Scripts = Just s}) <$> parsed (scriptList (Plutus.decodeCbor Plutus.V1)) bytes
        3 -> (\s -> value {auxiliaryPlutusV2Scripts = Just s}) <$> parsed (scriptList (Plutus.decodeCbor Plutus.V2)) bytes
        4 -> (\s -> value {auxiliaryPlutusV3Scripts = Just s}) <$> parsed (scriptList (Plutus.decodeCbor Plutus.V3)) bytes
        5 -> (\s -> value {auxiliaryPlutusV4Scripts = Just s}) <$> parsed (scriptList (Plutus.decodeCbor Plutus.V4)) bytes
        _ -> fail "Unknown auxiliary field"
      foldFields rest next
    parsed decoder = either (fail . show) pure . decoder
    scriptList decoder bytes = C.decodeAs InvalidAuxiliaryDataCbor (C.list (C.nested bytes decoder)) bytes
    unique [] = []
    unique (x : xs) = x : unique (filter (/= x) xs)

-- | A 32-byte Blake2b digest of full auxiliary CBOR.
newtype AuxiliaryDataHash = AuxiliaryDataHash ByteString deriving (Eq, Ord, Show)

-- | Validate a 32-byte auxiliary-data hash.
hashFromBytes :: ByteString -> Either Error AuxiliaryDataHash
hashFromBytes bytes
  | B.length bytes == 32 = Right (AuxiliaryDataHash bytes)
  | otherwise = Left (InvalidAuxiliaryDataCbor "Auxiliary-data hash must contain 32 bytes")

-- | Digest bytes.
hashBytes :: AuxiliaryDataHash -> ByteString
hashBytes (AuxiliaryDataHash bytes) = bytes

-- | Hash the full exact auxiliary encoding, including scripts and its envelope.
-- The native hashing boundary is explicit in IO.
hash :: EncodedAuxiliaryData -> IO (Either Error AuxiliaryDataHash)
hash value = fmap (AuxiliaryDataHash . Blake2b.toBytes) <$> Blake2b.compute 32 (toCbor value)
