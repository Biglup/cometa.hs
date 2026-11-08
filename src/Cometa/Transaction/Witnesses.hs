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

-- | Typed transaction witnesses with exact nested script/data encodings.
-- Collection order and imported duplicates are observable. Merging adds distinct
-- witnesses and rejects conflicting signatures or redeemer arguments.
-- @fromWitnesses empty@ creates an empty witness map for an unsigned transaction.
module Cometa.Transaction.Witnesses
  ( Witnesses,
    empty,
    mkWitnesses,
    verificationWitnesses,
    bootstrapWitnesses,
    scripts,
    datums,
    redeemers,
    merge,
    EncodedWitnesses,
    encodeCbor,
    encodeCborWith,
    SetField (..),
    setEncoding,
    withSetEncoding,
    decodeCbor,
    fromWitnesses,
    toWitnesses,
    toCbor,
    mergeEncoded,
    addVerificationWitness,
    removeKeyWitnesses,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Encoding.Set (SetEncoding)
import Cometa.Error (Error (..))
import qualified Cometa.Internal.SetEncoding as SetEncoding
import qualified Cometa.Internal.TransactionCbor as C
import qualified Cometa.PlutusData as Data
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Witness as Witness
import Control.Monad (foldM, unless)
import Data.ByteString (ByteString)
import qualified Data.List as List

-- TYPES ----------------------------------------------------------------------

-- | Immutable semantic values plus exact field encodings. Equality compares
-- field bytes; inspection exposes individual typed collections.
data Witnesses = Witnesses
  { witnessVerificationWitnesses :: ![Witness.VerificationWitness],
    witnessBootstrapWitnesses :: ![Witness.BootstrapWitness],
    witnessScripts :: ![Script.Script],
    witnessDatums :: ![Data.EncodedPlutusData],
    witnessRedeemers :: ![Redeemer.Redeemer],
    fields :: ![(Word, ByteString)]
  }
  deriving (Show)

instance Eq Witnesses where
  a == b = fields a == fields b

-- | Set-valued witness fields. Redeemers have a separate collection format.
data SetField
  = -- | Verification-key witnesses.
    VerificationKeys
  | -- | Native scripts.
    NativeScripts
  | -- | Byron bootstrap witnesses.
    BootstrapWitnesses
  | -- | Plutus V1 scripts.
    PlutusV1Scripts
  | -- | Witness datums.
    Datums
  | -- | Plutus V2 scripts.
    PlutusV2Scripts
  | -- | Plutus V3 scripts.
    PlutusV3Scripts
  | -- | Plutus V4 scripts.
    PlutusV4Scripts
  deriving (Eq, Ord, Show, Enum, Bounded)

-- DEFINITIONS ----------------------------------------------------------------

-- | Ordered Shelley key witnesses, including imported duplicates.
verificationWitnesses :: Witnesses -> [Witness.VerificationWitness]
verificationWitnesses = witnessVerificationWitnesses

-- | Ordered Byron bootstrap witnesses, including imported duplicates.
bootstrapWitnesses :: Witnesses -> [Witness.BootstrapWitness]
bootstrapWitnesses = witnessBootstrapWitnesses

-- | Scripts grouped by serialized language field; relative order and duplicates
-- within each language are preserved.
scripts :: Witnesses -> [Script.Script]
scripts = witnessScripts

-- | Ordered exact datum encodings, including duplicates.
datums :: Witnesses -> [Data.EncodedPlutusData]
datums = witnessDatums

-- | Redeemers sorted by purpose and zero-based body index.
redeemers :: Witnesses -> [Redeemer.Redeemer]
redeemers = witnessRedeemers

-- | All collections absent.
empty :: Witnesses
empty = Witnesses [] [] [] [] [] []

-- | Assemble ordered collections. Redeemers are sorted by purpose/index and
-- duplicate identifiers fail. Other collection order and duplicates are retained.
mkWitnesses :: [Witness.VerificationWitness] -> [Witness.BootstrapWitness] -> [Script.Script] -> [Data.EncodedPlutusData] -> [Redeemer.Redeemer] -> Either Error Witnesses
mkWitnesses keys boots scriptValues dataValues redeemerValues = do
  redeemerBytes <- Redeemer.encodeCollectionCbor redeemerValues
  let nativeValues = [n | Script.Native n <- scriptValues]
      plutusValues version = [p | Script.Plutus p <- scriptValues, Plutus.version p == version]
      entries =
        concat
          [ entry 0 Witness.encodeCbor keys,
            entry 1 Native.encodeCbor nativeValues,
            entry 2 Witness.encodeBootstrapCbor boots,
            entry 3 Plutus.encodeCbor (plutusValues Plutus.V1),
            entry 4 Data.toCbor dataValues,
            [(5, redeemerBytes) | not (null redeemerValues)],
            entry 6 Plutus.encodeCbor (plutusValues Plutus.V2),
            entry 7 Plutus.encodeCbor (plutusValues Plutus.V3),
            entry 8 Plutus.encodeCbor (plutusValues Plutus.V4)
          ]
  toWitnesses <$> decodeCbor (encodeFields entries)
  where
    entry _ _ [] = []
    entry key encoder values = [(key, encodeSet encoder values)]

encodeSet :: (a -> ByteString) -> [a] -> ByteString
encodeSet encoder values = C.encode (E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap (C.raw . encoder) values)

-- | Exact imported witness envelope. Equality compares full bytes.
data EncodedWitnesses = EncodedWitnesses !ByteString !Witnesses deriving (Show)

instance Eq EncodedWitnesses where
  a == b = toCbor a == toCbor b

instance Ord EncodedWitnesses where
  compare a b = compare (toCbor a) (toCbor b)

-- | Encode a definite map while retaining each exact stored field value.
encodeCbor :: Witnesses -> ByteString
encodeCbor = encodeFields . fields

encodeFields :: [(Word, ByteString)] -> ByteString
encodeFields values = C.encode (E.encodeMapLen (fromIntegral (length values)) <> foldMap (\(key, bytes) -> E.encodeWord key <> C.raw bytes) values)

-- | Retain an encoding of assembled witness data.
fromWitnesses :: Witnesses -> EncodedWitnesses
fromWitnesses value = EncodedWitnesses (encodeCbor value) value

-- | Observe typed witness collections.
toWitnesses :: EncodedWitnesses -> Witnesses
toWitnesses (EncodedWitnesses _ value) = value

-- | Full original witness-map bytes.
toCbor :: EncodedWitnesses -> ByteString
toCbor (EncodedWitnesses bytes _) = bytes

-- | Decode fields zero through eight, including Plutus V4. Unknown/duplicate
-- fields, invalid element lengths, duplicate redeemer identifiers and trailing
-- bytes fail. Tagged and untagged collections are accepted.
decodeCbor :: ByteString -> Either Error EncodedWitnesses
decodeCbor input = do
  values <- C.decodeAs InvalidWitnessCbor (C.entries ((,) <$> D.decodeWord <*> C.slice input)) input
  unless (length values == length (List.nub (map fst values))) (Left (InvalidWitnessCbor "Duplicate witness field"))
  decoded <- foldM parseField empty values
  pure (EncodedWitnesses input decoded {fields = values})
  where
    parseField value (key, bytes) = case key of
      0 -> (\xs -> value {witnessVerificationWitnesses = xs}) <$> set Witness.decodeCbor bytes
      1 -> (\xs -> value {witnessScripts = witnessScripts value ++ map Script.Native xs}) <$> set Native.decodeCbor bytes
      2 -> (\xs -> value {witnessBootstrapWitnesses = xs}) <$> set Witness.decodeBootstrapCbor bytes
      3 -> plutus value Plutus.V1 bytes
      4 -> (\xs -> value {witnessDatums = xs}) <$> set Data.decodeCbor bytes
      5 -> (\xs -> value {witnessRedeemers = xs}) <$> Redeemer.decodeCollectionCbor bytes
      6 -> plutus value Plutus.V2 bytes
      7 -> plutus value Plutus.V3 bytes
      8 -> plutus value Plutus.V4 bytes
      _ -> Left (InvalidWitnessCbor "Unknown witness field")
    plutus value version bytes = (\xs -> value {witnessScripts = witnessScripts value ++ map Script.Plutus xs}) <$> set (Plutus.decodeCbor version) bytes
    set decoder bytes = C.decodeAs InvalidWitnessCbor (C.setList (C.nested bytes decoder)) bytes

-- | Merge without overwriting existing signatures or redeemer budgets/arguments.
-- Identical additions are idempotent. Distinct additions follow existing elements;
-- untouched field encodings are preserved, including empty and historical forms.
-- Key/bootstrap equality compares their validated fields; script and datum
-- equality includes exact payload encodings, as does the redeemer argument.
merge :: Witnesses -> Witnesses -> Either Error Witnesses
merge left right = do
  keys <- mergeBy Witness.publicKey (witnessVerificationWitnesses left) (witnessVerificationWitnesses right)
  boots <- mergeBy Witness.bootstrapPublicKey (witnessBootstrapWitnesses left) (witnessBootstrapWitnesses right)
  rs <- mergeBy (\r -> (Redeemer.purpose r, Redeemer.index r)) (witnessRedeemers left) (witnessRedeemers right)
  fresh <- mkWitnesses keys boots (witnessScripts left `union` witnessScripts right) (witnessDatums left `union` witnessDatums right) rs
  let combined = map (retain fresh) (fields left) ++ [(key, bytes) | (key, bytes) <- fields fresh, key `notElem` map fst (fields left)]
  toWitnesses <$> decodeCbor (encodeFields combined)
  where
    retain fresh (key, original)
      | unchanged fresh key = (key, original)
      | otherwise = case lookup key (fields fresh) of
          Just updated -> (key, updated)
          Nothing -> (key, original)
    unchanged fresh key = case key of
      0 -> witnessVerificationWitnesses left == witnessVerificationWitnesses fresh
      2 -> witnessBootstrapWitnesses left == witnessBootstrapWitnesses fresh
      4 -> witnessDatums left == witnessDatums fresh
      5 -> witnessRedeemers left == witnessRedeemers fresh
      _ -> scriptsAt key left == scriptsAt key fresh
    scriptsAt key value = filter (belongs key) (witnessScripts value)
    belongs key value = case value of
      Script.Native _ -> key == 1
      Script.Plutus script ->
        key == case Plutus.version script of
          Plutus.V1 -> 3
          Plutus.V2 -> 6
          Plutus.V3 -> 7
          Plutus.V4 -> 8

mergeBy :: (Eq key, Eq value) => (value -> key) -> [value] -> [value] -> Either Error [value]
mergeBy project = foldM insert
  where
    insert values value = case filter ((== project value) . project) values of
      [] -> Right (values ++ [value])
      matches
        | all (== value) matches -> Right values
        | otherwise -> Left (WitnessConflict "Conflicting witness identity")

union :: (Eq a) => [a] -> [a] -> [a]
union = foldl (\values value -> if value `elem` values then values else values ++ [value])

-- | Merge exact envelopes. An addition with no semantic or representation change
-- returns the original envelope verbatim.
mergeEncoded :: EncodedWitnesses -> EncodedWitnesses -> Either Error EncodedWitnesses
mergeEncoded left right = do
  merged <- merge (toWitnesses left) (toWitnesses right)
  pure (if merged == toWitnesses left then left else fromWitnesses merged)

-- | Add a Shelley witness, rejecting a different signature for an existing key.
addVerificationWitness :: Witness.VerificationWitness -> EncodedWitnesses -> Either Error EncodedWitnesses
addVerificationWitness witness value = do
  addition <- mkWitnesses [witness] [] [] [] []
  mergeEncoded value (fromWitnesses addition)

-- | Remove Shelley and bootstrap signatures, retaining all other exact fields.
-- An envelope with no signatures is returned verbatim.
removeKeyWitnesses :: EncodedWitnesses -> EncodedWitnesses
removeKeyWitnesses encoded =
  let value = toWitnesses encoded
      retained = filter (\(key, _) -> key /= 0 && key /= 2) (fields value)
   in if length retained == length (fields value)
        then encoded
        else fromWitnesses value {witnessVerificationWitnesses = [], witnessBootstrapWitnesses = [], fields = retained}

-- | Encode with the requested tag on each present witness set. Nested datum and
-- script bytes remain unchanged; no absent collection is introduced.
encodeCborWith :: SetEncoding -> Witnesses -> ByteString
encodeCborWith requested value = toCbor (foldr (`withSetEncoding` requested) (fromWitnesses value) [minBound .. maxBound])

-- | Observe a witness collection's set tag; absent collections return 'Nothing'.
setEncoding :: SetField -> EncodedWitnesses -> Maybe SetEncoding
setEncoding field (EncodedWitnesses _ value) = SetEncoding.encoding <$> lookup (setFieldKey field) (fields value)

-- | Change only a present witness collection's set tag. Unchanged tags and absent
-- fields preserve the original envelope. Changes use a definite outer map while
-- retaining field order and exact nested bytes. Changing datum-set bytes can
-- require a new script-data hash and renewed transaction signatures.
withSetEncoding :: SetField -> SetEncoding -> EncodedWitnesses -> EncodedWitnesses
withSetEncoding field requested original@(EncodedWitnesses _ value)
  | updated == fields value = original
  | otherwise = EncodedWitnesses (encodeFields updated) value {fields = updated}
  where
    updated = [(key, if key == setFieldKey field then SetEncoding.withEncoding requested bytes else bytes) | (key, bytes) <- fields value]

-- | Ledger map key of a supported set-valued witness field.
setFieldKey :: SetField -> Word
setFieldKey field = case field of
  VerificationKeys -> 0
  NativeScripts -> 1
  BootstrapWitnesses -> 2
  PlutusV1Scripts -> 3
  Datums -> 4
  PlutusV2Scripts -> 6
  PlutusV3Scripts -> 7
  PlutusV4Scripts -> 8
