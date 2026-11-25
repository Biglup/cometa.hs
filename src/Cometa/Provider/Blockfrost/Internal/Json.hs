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

-- | Strict owned response values and the explicitly selected Ogmios v5 dialect.
module Cometa.Provider.Blockfrost.Internal.Json
  ( Row (..),
    decodeValue,
    parseValue,
    rows,
    transactionAddresses,
    parseHex,
    parseQuantity,
    parseNatural,
    parseAsset,
    assetText,
    nativeScript,
    decodeBudgets,
    evaluationPayload,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (..))
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Amount
import Control.Monad (unless, void, when, (>=>))
import Data.Aeson (Value (..), eitherDecodeStrict', object, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither, withArray, withObject, withScientific)
import Data.ByteString (ByteString)
import Data.Char (isDigit)
import Data.Foldable (toList, traverse_)
import Data.Maybe (fromMaybe, isJust)
import Data.Scientific (base10Exponent, toBoundedInteger)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as Text
import Data.Word (Word32, Word64)

-- TYPES ----------------------------------------------------------------------

data Row = Row
  { rowInput :: !Input.Input,
    rowAddress :: !Address.Address,
    rowValue :: !Amount.Value,
    rowDatum :: !Datum.Datum,
    rowDatumHash :: !(Maybe Datum.Hash32),
    rowScriptHash :: !(Maybe Credential.ScriptHash)
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

decodeValue :: Text -> ByteString -> Either Error Value
decodeValue operation = either (const (Left (InvalidProviderResponse operation))) Right . eitherDecodeStrict'

parseValue :: Text -> (Value -> Parser a) -> Value -> Either Error a
parseValue operation parser = either (const (Left (InvalidProviderResponse operation))) Right . parseEither parser

liftDomain :: Either Error a -> Parser a
liftDomain = either (const (fail "Invalid domain value")) pure

parseHex :: Text -> Parser ByteString
parseHex = maybe (fail "Invalid hexadecimal bytes") pure . Hex.decodeHex

parseQuantity :: Text -> Parser Word64
parseQuantity text
  | Text.null text || Text.length text > 20 || not (Text.all isDigit text) = fail "Invalid unsigned quantity"
  | otherwise = case Text.decimal text of
      Right (value, rest) | Text.null rest && value <= toInteger (maxBound :: Word64) -> pure (fromInteger value)
      _ -> fail "Unsigned quantity overflow"

parseNatural :: Value -> Parser Word64
parseNatural = withScientific "unsigned integer" $ \number ->
  if base10Exponent number < -100 || base10Exponent number > 100
    then fail "Numeric exponent exceeds response bounds"
    else case toBoundedInteger number :: Maybe Word64 of
      Just value -> pure value
      _ -> fail "Invalid unsigned integer"

parseAsset :: Text -> Parser AssetId
parseAsset "lovelace" = pure Ada
parseAsset text = do
  let (policy, name) = Text.splitAt 56 text
  Native <$> liftDomain (Policy.fromHex policy) <*> liftDomain (AssetName.fromHex name)

assetText :: AssetId -> Text
assetText Ada = "lovelace"
assetText (Native policy name) = Policy.toHex policy <> AssetName.toHex name

rows :: Value -> Parser [Row]
rows = withArray "UTxO list" (traverse row . toList)

row :: Value -> Parser Row
row = withObject "UTxO" $ \value -> do
  transaction <- value .: "tx_hash" >>= liftDomain . TxId.fromHex
  index <- value .: "output_index" >>= parseNatural
  address <- value .: "address" >>= liftDomain . Address.fromText
  amounts <- value .: "amount" >>= withArray "amounts" (traverse amount . toList)
  unless (Set.size (Set.fromList (map fst amounts)) == length amounts && any ((== Ada) . fst) amounts) (fail "Duplicate units or missing lovelace")
  hash <- value .: "data_hash" >>= traverse (parseHex >=> liftDomain . Datum.hashFromBytes)
  inline <- value .: "inline_datum" >>= traverse (parseHex >=> liftDomain . Data.decodeCbor)
  scriptHash <- value .: "reference_script_hash" >>= traverse (parseHex >=> liftDomain . Credential.scriptHashFromBytes)
  let datum = maybe (maybe Datum.NoDatum Datum.DatumHash hash) Datum.InlineDatum inline
      total = foldMap (\(asset, quantity) -> Amount.singleton asset (toInteger quantity)) amounts
  _ <- liftDomain (Output.mkOutput address total datum Nothing)
  pure (Row (Input.input transaction index) address total datum hash scriptHash)
  where
    amount = withObject "amount" $ \value -> (,) <$> (value .: "unit" >>= parseAsset) <*> (value .: "quantity" >>= parseQuantity)

-- A transaction endpoint describes historical outputs. Only extract the address
-- needed for a current address-UTxO cross-check; never call these outputs unspent.
transactionAddresses :: TxId.TransactionId -> Value -> Parser [(Input.Input, Address.Address)]
transactionAddresses expected = withObject "transaction outputs" $ \value -> do
  actual <- value .: "hash" >>= liftDomain . TxId.fromHex
  unless (actual == expected) (fail "Transaction identity mismatch")
  outputs <- value .: "outputs" >>= withArray "outputs" (traverse output . toList)
  unless (Set.size (Set.fromList (map (\(reference, _, _) -> Input.index reference) outputs)) == length outputs) (fail "Duplicate output index")
  pure [(reference, address) | (reference, address, unspent) <- outputs, unspent]
  where
    output = withObject "output address" $ \value -> do
      address <- value .: "address" >>= liftDomain . Address.fromText
      index <- value .: "output_index" >>= parseNatural
      consumed <- value .:? "consumed_by_tx"
      case consumed of
        Nothing -> pure ()
        Just hash -> void (liftDomain (TxId.fromHex hash))
      pure (Input.input expected index, address, consumed == (Nothing :: Maybe Text))

nativeScript :: Value -> Parser Native.NativeScript
nativeScript = withObject "native script" $ \value -> do
  kind <- value .: "type"
  case kind :: Text of
    "sig" -> Native.signature <$> (value .: "keyHash" >>= parseHex >>= liftDomain . Credential.keyHashFromBytes)
    "all" -> Native.allOf <$> (value .: "scripts" >>= traverse nativeScript)
    "any" -> Native.anyOf <$> (value .: "scripts" >>= traverse nativeScript)
    "atLeast" -> Native.atLeast <$> (value .: "required" >>= parseNatural) <*> (value .: "scripts" >>= traverse nativeScript)
    "before" -> Native.invalidAfter <$> (value .: "slot" >>= parseNatural)
    "after" -> Native.invalidBefore <$> (value .: "slot" >>= parseNatural)
    _ -> fail "Unsupported native script"

decodeBudgets :: Tx.Transaction -> Value -> Either Error Evaluation.Budgets
decodeBudgets transaction value = do
  case value of
    Object envelope | Just (Object result) <- KeyMap.lookup "result" envelope, KeyMap.member "EvaluationFailure" result -> Left (InvalidEvaluationResult "Blockfrost script evaluation failed")
    _ -> pure ()
  pairs <- parseValue operation parser value
  budgets <- Evaluation.mkBudgets pairs
  let expected = Set.fromList [Evaluation.RedeemerId (Redeemer.purpose redeemer) (Redeemer.index redeemer) | redeemer <- Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses transaction))]
  unless (Set.fromList (map fst (Evaluation.budgets budgets)) == expected) (Left (InvalidEvaluationResult "Blockfrost budgets do not cover exactly the existing redeemers"))
  pure budgets
  where
    operation = "blockfrost.evaluateTransaction"
    parser = withObject "evaluation envelope" $ \envelope -> envelope .: "result" >>= withObject "evaluation result" (\result -> result .: "EvaluationResult" >>= withObject "budgets" (traverse budget . KeyMap.toList))
    budget (key, payload) = do
      identifier <- pointer (Key.toText key)
      units <- withObject "budget" (\entry -> ExUnits <$> (entry .: "memory" >>= parseNatural) <*> (entry .: "steps" >>= parseNatural)) payload
      pure (identifier, units)
    pointer text = case Text.splitOn ":" text of
      [purpose, index] -> do
        tag <- case purpose of
          "spend" -> pure Redeemer.Spending
          "mint" -> pure Redeemer.Minting
          "certificate" -> pure Redeemer.Certifying
          "withdrawal" -> pure Redeemer.Rewarding
          _ -> fail "Unsupported redeemer purpose"
        number <- parseQuantity index
        when (number > fromIntegral (maxBound :: Word32)) (fail "Redeemer index overflow")
        pure (Evaluation.RedeemerId tag (fromIntegral number))
      _ -> fail "Invalid redeemer pointer"

evaluationPayload :: Tx.Transaction -> [Utxo.Utxo] -> Either Error Value
evaluationPayload transaction resolved = do
  let redeemers = Witnesses.redeemers (Witnesses.toWitnesses (Tx.witnesses transaction))
      body = Body.toBody (Tx.body transaction)
      fields = Body.bodyFields body
      subs = fromMaybe [] (Body.bodySubTransactions body)
      unsupportedFields = [isJust (Fields.fieldDirectDeposits fields), isJust (Fields.fieldAccountBalanceIntervals fields), isJust (Fields.fieldRequiredTopLevelGuards fields), isJust (Body.bodyStartingAccountBalanceIntervals body), isJust (Fields.fieldVotingProcedures fields), isJust (Fields.fieldProposalProcedures fields), isJust (Fields.fieldTreasuryValue fields), isJust (Fields.fieldDonation fields)]
      hasScriptGuard = any isScriptGuard (fromMaybe [] (Fields.fieldGuards fields))
  unless (null subs && not (or unsupportedFields) && not hasScriptGuard && all ((<= Redeemer.Rewarding) . Redeemer.purpose) redeemers) unsupported
  unless (Set.size (Set.fromList (map Utxo.input resolved)) == length resolved) (Left (InvalidEvaluationRequest "Duplicate resolved input reference"))
  traverse_ scriptValue (Witnesses.scripts (Witnesses.toWitnesses (Tx.witnesses transaction)))
  additional <- traverse utxoValue resolved
  pure (object ["cbor" .= Hex.encodeHex (Tx.encodeCbor transaction), "additionalUtxoSet" .= additional])
  where
    isScriptGuard (Credential.ScriptCredential _) = True
    isScriptGuard _ = False
    unsupported = Left (UnsupportedOperation "Blockfrost Ogmios v5 cannot represent this evaluation feature")
    utxoValue utxo = do
      let input = Utxo.input utxo
          output = Utxo.output utxo
      unless (Input.index input <= fromIntegral (maxBound :: Word32)) unsupported
      reference <- traverse scriptValue (Output.referenceScript output)
      let value = Output.value output
          assets = KeyMap.fromList [(Key.fromText (Policy.toHex policy <> if AssetName.toHex name == "" then "" else "." <> AssetName.toHex name), toJSONInteger quantity) | (Native policy name, quantity) <- Amount.toList value]
          -- The hosted evaluator rejects a present empty assets map. Omit the
          -- optional field for Ada-only values; nonempty maps retain their keys.
          valueFields = ["coins" .= Amount.quantity Ada value] <> ["assets" .= Object assets | not (KeyMap.null assets)]
          (datumHash, datum) = case Output.datum output of
            Datum.NoDatum -> (Null, Null)
            Datum.DatumHash hash -> (String (Hex.encodeHex (Datum.hashBytes hash)), Null)
            Datum.InlineDatum encoded -> (Null, String (Hex.encodeHex (Data.toCbor encoded)))
      pure
        [ object ["txId" .= TxId.toHex (Input.transactionId input), "index" .= Input.index input],
          object ["address" .= Address.toText (Output.address output), "value" .= object valueFields, "datumHash" .= datumHash, "datum" .= datum, "script" .= fromMaybe Null reference]
        ]
    scriptValue (Script.Native script) = object . pure . ("native" .=) <$> nativeValue script
    scriptValue (Script.Plutus script) = case Plutus.version script of
      Plutus.V1 -> Right (object ["plutus:v1" .= Hex.encodeHex (Plutus.toBytes script)])
      Plutus.V2 -> Right (object ["plutus:v2" .= Hex.encodeHex (Plutus.toBytes script)])
      _ -> unsupported
    nativeValue script = case Native.view script of
      Native.RequireSignature key -> Right (String (Hex.encodeHex (Credential.keyHashBytes key)))
      Native.RequireAll children -> object . pure . ("all" .=) <$> traverse nativeValue children
      Native.RequireAny children -> object . pure . ("any" .=) <$> traverse nativeValue children
      Native.RequireAtLeast count children -> object . pure . (Key.fromText (Text.pack (show count)) .=) <$> traverse nativeValue children
      Native.InvalidBefore slot -> Right (object ["startsAt" .= slot])
      Native.InvalidAfter slot -> Right (object ["expiresAt" .= slot])
      Native.RequireGuard _ -> unsupported
    toJSONInteger = Number . fromInteger
