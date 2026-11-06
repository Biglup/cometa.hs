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
{-# LANGUAGE RankNTypes #-}

-- | Owned transaction outputs with validated quantities, explicit datum choice
-- and optional reference scripts. This module does not check minimum Ada or
-- ledger admission rules.
--
-- @
-- payment address = mkOutput address (Value.lovelace 2000000) Datum.NoDatum Nothing
-- @
module Cometa.Transaction.Output
  ( Output,
    mkOutput,
    address,
    value,
    datum,
    referenceScript,
    encodeCbor,
    EncodedOutput,
    decodeCbor,
    fromOutput,
    toOutput,
    toCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Address (Address)
import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (Ada))
import Cometa.Error (Error)
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Internal.TransactionValue as V
import qualified Cometa.PlutusData as Data
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import Cometa.Transaction.Datum (Datum (..))
import qualified Cometa.Transaction.Datum as Datum
import Cometa.Value (Value)
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | A semantic output. Equality compares fields, including inline datum encoding.
-- Quantities are nonnegative and no greater than 2^63 - 1.
-- Inspecting an immutable output is pure.
data Output = Output !Address !Value !Datum !(Maybe Script) deriving (Eq, Show)

-- | Exact imported or freshly encoded output. Equality compares encoded bytes.
data EncodedOutput = EncodedOutput !ByteString !Output deriving (Show)

instance Eq EncodedOutput where
  left == right = toCbor left == toCbor right

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate every output quantity once. Negative quantities and quantities
-- greater than 2^63 - 1 return 'Cometa.Error.InvalidTransactionOutputValue'.
-- Address, datum and script values have already passed their own validation.
mkOutput :: Address -> Value -> Datum -> Maybe Script -> Either Error Output
mkOutput destination amount dat script = do
  V.validateOutput amount
  pure (Output destination amount dat script)

-- | Destination address. Reward addresses are representable without asserting
-- that a ledger accepts them as payment destinations.
address :: Output -> Address
address (Output result _ _ _) = result

-- | Nonnegative bundle; Ada quantities are lovelace.
value :: Output -> Value
value (Output _ result _ _) = result

-- | No datum, its hash, or exact inline data.
datum :: Output -> Datum
datum (Output _ _ result _) = result

-- | Optional reusable reference script, distinct from a spending witness.
referenceScript :: Output -> Maybe Script
referenceScript (Output _ _ _ result) = result

-- | Fresh Babbage-style map. Optional absent fields are omitted; inline data
-- and scripts are wrapped in tag 24 byte strings. Datum bytes remain exact.
encodeCbor :: Output -> ByteString
encodeCbor (Output destination amount dat script) = Cbor.encode (E.encodeMapLen (fromIntegral (length fields)) <> foldMap (\(key, payload) -> E.encodeWord key <> payload) fields)
  where
    assets = Value.toList (Value.difference amount (Value.lovelace (Value.quantity Ada amount)))
    coin = E.encodeInteger (Value.quantity Ada amount)
    amountEncoding = if null assets then coin else E.encodeListLen 2 <> coin <> V.encodeAssets amount
    fields = [(0, E.encodeBytes (Address.toBytes destination)), (1, amountEncoding)] ++ datumField ++ maybe [] (\s -> [(3, E.encodeTag 24 <> E.encodeBytes (Script.encodeCbor s))]) script
    datumField = case dat of
      NoDatum -> []
      DatumHash hash -> [(2, E.encodeListLen 2 <> E.encodeWord 0 <> E.encodeBytes (Datum.hashBytes hash))]
      InlineDatum payload -> [(2, E.encodeListLen 2 <> E.encodeWord 1 <> E.encodeTag 24 <> E.encodeBytes (Data.toCbor payload))]

-- | Pair semantic output with a fresh encoding.
fromOutput :: Output -> EncodedOutput
fromOutput output = EncodedOutput (encodeCbor output) output

-- | Inspect semantic output fields. Re-encoding may change imported legacy form.
toOutput :: EncodedOutput -> Output
toOutput (EncodedOutput _ output) = output

-- | Exact imported or freshly encoded bytes.
toCbor :: EncodedOutput -> ByteString
toCbor (EncodedOutput bytes _) = bytes

-- | Decode exactly one legacy array or Babbage map, rejecting unknown or duplicate
-- keys, malformed datum/script envelopes, invalid quantities and trailing bytes.
-- Legacy arrays contain address, value and optionally a datum hash. Original
-- bytes are retained independently of the semantic output.
decodeCbor :: ByteString -> Either Error EncodedOutput
decodeCbor bytes = EncodedOutput bytes <$> Cbor.decode parser bytes
  where
    parser = do
      token <- D.peekTokenType
      if token == D.TypeMapLen || token == D.TypeMapLenIndef then mapOutput else legacyOutput
    validate destination amount dat script = either (fail . show) pure (mkOutput destination amount dat script)
    addressParser = D.decodeBytes >>= either (fail . show) pure . Address.fromBytes
    valueParser = do
      token <- D.peekTokenType
      (coin, assets) <-
        if token == D.TypeUInt || token == D.TypeUInt64
          then (,) <$> D.decodeInteger <*> pure mempty
          else Cbor.array 2 ((,) <$> D.decodeInteger <*> V.decodeAssets)
      unless (coin >= 0 && coin <= toInteger (maxBound :: Int64)) (fail "Output coin exceeds nonnegative int64")
      pure (Value.lovelace coin <> assets)
    decodeField :: (forall s. D.Decoder s a) -> Word64 -> Map.Map Word64 ByteString -> D.Decoder t a
    decodeField parser' key fields = case Map.lookup key fields of
      Nothing -> fail "Missing required output field"
      Just payload -> either (fail . show) pure (Cbor.decode parser' payload)
    optionalField :: (forall s. D.Decoder s a) -> Word64 -> Map.Map Word64 ByteString -> D.Decoder t (Maybe a)
    optionalField parser' key fields = traverse (either (fail . show) pure . Cbor.decode parser') (Map.lookup key fields)
    mapOutput = do
      fields <- Cbor.mapFields bytes
      unless (all (`elem` [0, 1, 2, 3]) (Map.keys fields)) (fail "Unknown output field")
      destination <- decodeField addressParser 0 fields
      amount <- decodeField valueParser 1 fields
      dat <- fromMaybe NoDatum <$> optionalField datumParser 2 fields
      script <- optionalField scriptParser 3 fields
      validate destination amount dat script
    datumParser = Cbor.array 2 $ do
      kind <- D.decodeWord
      case kind of
        0 -> DatumHash <$> (D.decodeBytes >>= either (fail . show) pure . Datum.hashFromBytes)
        1 -> InlineDatum <$> (embedded >>= either (fail . show) pure . Data.decodeCbor)
        _ -> fail "Invalid datum alternative"
    scriptParser = embedded >>= either (fail . show) pure . Script.decodeCbor
    embedded = do
      tag <- D.decodeTag
      unless (tag == 24) (fail "Expected embedded CBOR tag24")
      D.decodeBytes
    legacyOutput = do
      count <- D.decodeListLenOrIndef
      unless (maybe True (`elem` [2, 3]) count) (fail "Invalid legacy output arity")
      destination <- addressParser
      amount <- valueParser
      hasDatum <- case count of
        Just 3 -> pure True
        Just _ -> pure False
        Nothing -> not <$> D.decodeBreakOr
      dat <- if hasDatum then DatumHash <$> (D.decodeBytes >>= either (fail . show) pure . Datum.hashFromBytes) else pure NoDatum
      case count of
        Nothing | hasDatum -> D.decodeBreakOr >>= \ended -> unless ended (fail "Extra legacy output field")
        _ -> pure ()
      validate destination amount dat Nothing
