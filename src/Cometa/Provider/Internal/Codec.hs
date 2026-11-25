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
{-# OPTIONS_HADDOCK hide #-}

-- | Owned ledger values for the Koios and Ogmios wire formats.
module Cometa.Provider.Internal.Codec
  ( parse,
    field,
    list,
    natural,
    checked,
    inputText,
    input,
    unique,
    datum,
    script,
    koiosOutput,
    ogmiosOutput,
    evaluationPayload,
    budgets,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (..))
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.ExUnits as Units
import qualified Cometa.Provider.Blockfrost.Internal.Json as Json
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Amount
import Control.Monad (unless, when, (>=>))
import Control.Monad.Trans.Except (ExceptT (..), except, throwE)
import Data.Aeson (Value (..), object, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, withArray, withObject)
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

-- DEFINITIONS ----------------------------------------------------------------

parse :: (Value -> Parser a) -> Value -> Either Error a
parse = Json.parseValue "provider.response"

checked :: Either Error a -> Parser a
checked = either (const (fail "Invalid ledger value")) pure

field :: Text -> Value -> Parser Value
field name = withObject "object" (.: Key.fromText name)

list :: Value -> Parser [Value]
list = withArray "array" (pure . toList)

natural :: Value -> Parser Word64
natural (String value) = Json.parseQuantity value
natural value = Json.parseNatural value

inputText :: Input.Input -> Text
inputText value = TxId.toHex (Input.transactionId value) <> "#" <> Text.pack (show (Input.index value))

input :: Text -> Text -> Value -> Parser Input.Input
input hashKey indexKey = withObject "output reference" $ \entry -> do
  tx <- entry .: Key.fromText hashKey >>= checked . TxId.fromHex
  index <- entry .: Key.fromText indexKey >>= natural
  when (index > 65535) (fail "Output index exceeds ledger bounds")
  pure (Input.input tx index)

unique :: (Ord a) => [a] -> Either Error ()
unique values = unless (Set.size (Set.fromList values) == length values) (Left (InvalidProviderResponse "Duplicate response identity"))

-- Hash checks are effectful native operations; decoded values remain Haskell-owned.
datum :: Datum.Hash32 -> Text -> ExceptT Error IO Data.EncodedPlutusData
datum expected text = do
  bytes <- except (parse (const (Json.parseHex text)) Null)
  encoded <- except (Data.decodeCbor bytes)
  hash <- ExceptT (Data.hash encoded)
  unless (Blake2b.toBytes hash == Datum.hashBytes expected) (throwE (InvalidProviderResponse "Datum hash mismatch"))
  pure encoded

script :: Text -> Maybe Text -> Maybe Value -> Text -> ExceptT Error IO Script.Script
script language bytes json expected = do
  value <- except $ parse (const decode) Null
  hash <- ExceptT (Script.hash value)
  unless (Hex.encodeHex (Credential.scriptHashBytes hash) == Text.toLower expected) (throwE (InvalidProviderResponse "Reference script hash mismatch"))
  pure value
  where
    decode = case language of
      "timelock" | Nothing <- bytes, Just value <- json -> Script.Native <$> Json.nativeScript value
      "timelock" -> native
      "native" -> native
      _ -> do
        version <- maybe (fail "Unsupported reference script language") pure (lookup language versions)
        Script.Plutus <$> (raw >>= checked . Plutus.fromBytes version)
    raw = maybe (fail "Missing script bytes") Json.parseHex bytes
    native = Script.Native <$> (raw >>= checked . Native.decodeCbor)
    versions =
      [ ("plutusV1", Plutus.V1),
        ("plutusV2", Plutus.V2),
        ("plutusV3", Plutus.V3),
        ("plutusV4", Plutus.V4),
        ("plutus:v1", Plutus.V1),
        ("plutus:v2", Plutus.V2),
        ("plutus:v3", Plutus.V3),
        ("plutus:v4", Plutus.V4)
      ]

koiosOutput :: Value -> ExceptT Error IO Utxo.Utxo
koiosOutput source = do
  (reference, address, amount, hash, inline, referenceScript) <- except (parse parser source)
  dat <- case (hash, inline) of
    (Just expected, Just bytes) -> Datum.InlineDatum <$> datum expected bytes
    (Nothing, Just _) -> throwE (InvalidProviderResponse "Missing inline datum hash")
    (Just expected, Nothing) -> pure (Datum.DatumHash expected)
    _ -> pure Datum.NoDatum
  ref <- traverse (\(kind, bytes, json, expected) -> script kind bytes json expected) referenceScript
  output <- except (Output.mkOutput address amount dat ref)
  pure (Utxo.utxo reference output)
  where
    parser = withObject "Koios output" $ \entry -> do
      reference <- input "tx_hash" "tx_index" (Object entry)
      address <- entry .: "address" >>= checked . Address.fromText
      coins <- entry .: "value" >>= natural
      assets <- entry .:? "asset_list" >>= traverse asset . fromMaybe []
      checked (unique (map fst assets))
      hash <- entry .:? "datum_hash" >>= traverse (Json.parseHex >=> checked . Datum.hashFromBytes)
      inline <- entry .:? "inline_datum" >>= traverse (withObject "inline datum" (.: "bytes"))
      ref <- entry .:? "reference_script" >>= traverse (withObject "reference script" (\s -> (,,,) <$> s .: "type" <*> s .:? "bytes" <*> s .:? "value" <*> s .: "hash"))
      pure (reference, address, Amount.lovelace (toInteger coins) <> foldMap (uncurry Amount.singleton) assets, hash, inline, ref)
    asset = withObject "asset" $ \entry -> do
      policy <- entry .: "policy_id" >>= checked . Policy.fromHex
      name <- entry .: "asset_name" >>= checked . AssetName.fromHex
      quantity <- entry .: "quantity" >>= natural
      when (quantity == 0) (fail "Zero asset quantity")
      pure (Native policy name, toInteger quantity)

ogmiosOutput :: Utxo.Utxo -> Either Error Value
ogmiosOutput utxo = do
  unless (Input.index reference <= 65535) (Left (InvalidEvaluationRequest "Output index exceeds ledger bounds"))
  let amounts = Amount.toList (Output.value output)
      policies = Map.fromListWith (<>) [(Policy.toHex policy, [(Key.fromText (AssetName.toHex name), Number (fromInteger quantity))]) | (Native policy name, quantity) <- amounts]
      value = Object (KM.fromList (("ada", object ["lovelace" .= Amount.quantity Ada (Output.value output)]) : [(Key.fromText policy, Object (KM.fromList entries)) | (policy, entries) <- Map.toList policies]))
      dat = case Output.datum output of
        Datum.NoDatum -> []
        Datum.DatumHash hash -> ["datumHash" .= Hex.encodeHex (Datum.hashBytes hash)]
        Datum.InlineDatum encoded -> ["datum" .= Hex.encodeHex (Data.toCbor encoded)]
      ref = case Output.referenceScript output of
        Nothing -> []
        Just (Script.Native native) -> ["script" .= object ["language" .= ("native" :: Text), "cbor" .= Hex.encodeHex (Native.encodeCbor native)]]
        Just (Script.Plutus plutus) -> ["script" .= object ["language" .= language (Plutus.version plutus), "cbor" .= Hex.encodeHex (Plutus.toBytes plutus)]]
  pure
    ( object
        ( [ "transaction" .= object ["id" .= TxId.toHex (Input.transactionId reference)],
            "index" .= Input.index reference,
            "address" .= Address.toText (Output.address output),
            "value" .= value
          ]
            <> dat
            <> ref
        )
    )
  where
    reference = Utxo.input utxo
    output = Utxo.output utxo
    language version = case version of Plutus.V1 -> "plutus:v1" :: Text; Plutus.V2 -> "plutus:v2"; Plutus.V3 -> "plutus:v3"; Plutus.V4 -> "plutus:v4"

evaluationPayload :: Tx.Transaction -> [Utxo.Utxo] -> Either Error Value
evaluationPayload transaction additional = do
  unique (map Utxo.input additional)
  outputs <- traverse ogmiosOutput additional
  pure $ object ["transaction" .= object ["cbor" .= cbor], "additionalUtxo" .= outputs]
  where
    cbor = Hex.encodeHex (Tx.encodeCbor transaction)

budgets :: Tx.Transaction -> Value -> Either Error Evaluation.Budgets
budgets transaction value = do
  pairs <- parse (list >=> traverse budget) value
  result <- Evaluation.mkBudgets pairs
  let expected = Set.fromList [Evaluation.RedeemerId (Redeemer.purpose r) (Redeemer.index r) | r <- Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses transaction))]
  unless (Set.fromList (map fst pairs) == expected) (Left (InvalidEvaluationResult "Budgets must cover exactly the existing redeemers"))
  pure result
  where
    budget = withObject "budget" $ \entry -> do
      validator <- entry .: "validator"
      (purpose, index) <- withObject "validator" (\v -> (,) <$> v .: "purpose" <*> (v .: "index" >>= natural)) validator
      when (index > 4294967295) (fail "Redeemer index overflow")
      tag <- maybe (fail "Unsupported redeemer purpose") pure (lookup purpose tags)
      units <- entry .: "budget" >>= withObject "units" (\u -> Units.ExUnits <$> (u .: "memory" >>= natural) <*> (u .: "cpu" >>= natural))
      pure (Evaluation.RedeemerId tag (fromIntegral index), units)
    tags =
      [ ("spend" :: Text, Redeemer.Spending),
        ("mint", Redeemer.Minting),
        ("publish", Redeemer.Certifying),
        ("withdraw", Redeemer.Rewarding),
        ("vote", Redeemer.Voting),
        ("propose", Redeemer.Proposing)
      ]
