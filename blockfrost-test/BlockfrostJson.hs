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

-- | New deterministic codec fixtures; no live account or funded transaction.
module BlockfrostJson (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as Name
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Provider.Blockfrost.Internal.Json as Json
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Amount
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Aeson.Types
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Scientific (scientific)
import qualified Data.Text as Text
import Data.Word (Word64)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Blockfrost JSON codecs"
    [ testCase "quantity and scientific integer bounds remain exact" integers,
      testCase "asset units roundtrip and reject invalid policy/name bytes" assets,
      testCase "UTxO amounts and inline datum bytes retain typed values" utxos,
      testCase "nullable fields are required and duplicate semantic assets fail" invalidRows,
      testCase "native JSON timelocks and threshold children map precisely" nativeScripts,
      testCase "historical output addresses require identity and unique indices" historical,
      testCase "evaluation budgets cover exactly four supported purposes" budgets,
      testCase "Ogmios v5 payload retains CBOR, datum choice and reference script" payload,
      testCase "Ada-only supplemental evaluation values omit the empty assets field" adaOnlyPayload
    ]

parse :: (Value -> Data.Aeson.Types.Parser a) -> Value -> Either Error a
parse = Json.parseValue "fixture"

integers :: IO ()
integers = do
  parse Json.parseNatural (Number 9007199254740993) @?= Right 9007199254740993
  parse Json.parseNatural (Number 18446744073709551615) @?= Right (maxBound :: Word64)
  Json.parseValue "fixture" (\_ -> Json.parseQuantity "18446744073709551615") Null @?= Right (maxBound :: Word64)
  forM_ [Number (-1), Number 0.5, Number 18446744073709551616, Number (scientific 1 1000000), Number (scientific 1 minBound), Number (scientific 10 maxBound)] $ \value ->
    assertBool "invalid number" (isLeft (parse Json.parseNatural value))
  forM_ ["-1", "+1", "1.1", "18446744073709551616", "123456789012345678901", ""] $ \quantity ->
    assertBool "invalid decimal string" (isLeft (Json.parseValue "fixture" (\_ -> Json.parseQuantity quantity) Null))

assets :: IO ()
assets = do
  policy <- require (Policy.fromBytes (B.replicate 28 1))
  name <- require (Name.fromBytes (B.pack [0, 255]))
  forM_ [AssetId.Ada, AssetId.Native policy Name.empty, AssetId.Native policy name] $ \asset ->
    Json.parseValue "fixture" (\_ -> Json.parseAsset (Json.assetText asset)) Null @?= Right asset
  forM_ ["LOVELACE", Text.replicate 55 "0", Text.replicate 56 "z", Text.replicate 56 "0" <> "f", Text.replicate 56 "0" <> Text.replicate 66 "a"] $ \unit ->
    assertBool "invalid asset" (isLeft (Json.parseValue "fixture" (\_ -> Json.parseAsset unit) Null))

fixtureAddress :: IO Address.Address
fixtureAddress = require (Address.fromBytes (B.cons 0x60 (B.replicate 28 1)))

rowValue :: IO Value
rowValue = do
  address <- fixtureAddress
  pure $
    object
      [ "tx_hash" .= Text.replicate 64 "0",
        "output_index" .= (0 :: Int),
        "address" .= Address.toText address,
        "amount" .= [object ["unit" .= String "lovelace", "quantity" .= String "9007199254740993"]],
        "data_hash" .= Null,
        "inline_datum" .= Null,
        "reference_script_hash" .= Null
      ]

replace :: Data.Aeson.Key.Key -> Value -> Value -> Value
replace key replacement (Object fields) = Object (KeyMap.insert key replacement fields)
replace _ _ original = original

utxos :: IO ()
utxos = do
  base <- rowValue
  let inline = replace "inline_datum" (String "1818") (replace "data_hash" (String (Text.replicate 64 "1")) base)
  decoded <- require (parse Json.rows (toJSON [inline]))
  case decoded of
    [entry] -> do
      Input.index (Json.rowInput entry) @?= 0
      Amount.quantity AssetId.Ada (Json.rowValue entry) @?= 9007199254740993
      case Json.rowDatum entry of
        Datum.InlineDatum value -> Data.toCbor value @?= B.pack [0x18, 0x18]
        other -> assertFailure (show other)
      fmap Datum.hashBytes (Json.rowDatumHash entry) @?= Just (B.replicate 32 0x11)
    _ -> assertFailure "wrong row count"

invalidRows :: IO ()
invalidRows = do
  base <- rowValue
  forM_ ["data_hash", "inline_datum", "reference_script_hash"] $ \key -> case base of
    Object fields -> assertBool "documented nullable field is required" (isLeft (parse Json.rows (toJSON [Object (KeyMap.delete key fields)])))
    _ -> assertFailure "invalid object fixture"
  let duplicate = replace "amount" (toJSON [object ["unit" .= String "lovelace", "quantity" .= String "1"], object ["unit" .= String "lovelace", "quantity" .= String "2"]]) base
      noAda = replace "amount" (toJSON ([] :: [Value])) base
      overflowing = replace "amount" (toJSON [object ["unit" .= String "lovelace", "quantity" .= String "9223372036854775808"]]) base
  forM_ [duplicate, noAda, overflowing, replace "inline_datum" (String "ff") base, replace "reference_script_hash" (String "00") base] $ \value ->
    assertBool "invalid row" (isLeft (parse Json.rows (toJSON [value])))

nativeScripts :: IO ()
nativeScripts = do
  key <- require (Credential.keyHashFromBytes (B.replicate 28 1))
  let sig = object ["type" .= String "sig", "keyHash" .= Hex.encodeHex (B.replicate 28 1)]
      samples =
        [ (sig, Native.signature key),
          (object ["type" .= String "before", "slot" .= (12 :: Int)], Native.invalidAfter 12),
          (object ["type" .= String "after", "slot" .= (34 :: Int)], Native.invalidBefore 34),
          (object ["type" .= String "all", "scripts" .= [sig]], Native.allOf [Native.signature key]),
          (object ["type" .= String "any", "scripts" .= [sig]], Native.anyOf [Native.signature key]),
          (object ["type" .= String "atLeast", "required" .= (1 :: Int), "scripts" .= [sig]], Native.atLeast 1 [Native.signature key])
        ]
  forM_ samples $ \(value, expected) ->
    fmap Native.encodeCbor (parse Json.nativeScript value) @?= Right (Native.encodeCbor expected)
  assertBool "unsupported native type" (isLeft (parse Json.nativeScript (object ["type" .= String "requireGuard"])))

historical :: IO ()
historical = do
  txId <- require (TxId.fromBytes (B.replicate 32 0))
  address <- fixtureAddress
  let item = object ["address" .= Address.toText address, "output_index" .= (1 :: Int)]
      value = object ["hash" .= TxId.toHex txId, "outputs" .= [item]]
  parse (Json.transactionAddresses txId) value @?= Right [(Input.input txId 1, address)]
  assertBool "duplicate output index" (isLeft (parse (Json.transactionAddresses txId) (replace "outputs" (toJSON [item, item]) value)))
  assertBool "wrong transaction hash" (isLeft (parse (Json.transactionAddresses txId) (replace "hash" (String (Text.replicate 64 "1")) value)))

transaction :: [Redeemer.Purpose] -> IO Tx.Transaction
transaction purposes = do
  body <- require (Body.fromBody (Body.body [] [] 0))
  let argument = Data.fromData (Data.Integer 0)
      values = [Redeemer.Redeemer purpose 0 argument (ExUnits 0 0) | purpose <- purposes]
  witnesses <- require (Witnesses.mkWitnesses [] [] [] [] values)
  pure (Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing)

budgets :: IO ()
budgets = do
  tx <- transaction [Redeemer.Spending, Redeemer.Minting, Redeemer.Certifying, Redeemer.Rewarding]
  let result = object [key .= object ["memory" .= (100 + n :: Int), "steps" .= (1000 + n :: Int)] | (key, n) <- zip ["spend:0", "mint:0", "certificate:0", "withdrawal:0"] [0 ..]]
      envelope entries = object ["result" .= object ["EvaluationResult" .= entries]]
  decoded <- require (Json.decodeBudgets tx (envelope result))
  map snd (Evaluation.budgets decoded) @?= [ExUnits 100 1000, ExUnits 101 1001, ExUnits 102 1002, ExUnits 103 1003]
  forM_ [object [], object ["spend:4294967296" .= object ["memory" .= (1 :: Int), "steps" .= (1 :: Int)]], object ["vote:0" .= object ["memory" .= (1 :: Int), "steps" .= (1 :: Int)]]] $ \value ->
    assertBool "incomplete/unsupported budget set" (isLeft (Json.decodeBudgets tx (envelope value)))

payload :: IO ()
payload = do
  tx <- transaction []
  txId <- require (TxId.fromBytes (B.replicate 32 0))
  address <- fixtureAddress
  policy <- require (Policy.fromBytes (B.replicate 28 1))
  name <- require (Name.fromBytes (B.singleton 255))
  script <- require (Plutus.fromBytes Plutus.V2 (B.pack [0x45, 1, 0, 0, 0x24, 0x99]))
  hashed <- require (Datum.hashFromBytes (B.replicate 32 2))
  let amount = Amount.lovelace 42 <> Amount.singleton (AssetId.Native policy name) 7
      inline = Data.fromData (Data.Integer 24)
  output <- require (Output.mkOutput address amount (Datum.InlineDatum inline) (Just (Script.Plutus script)))
  hashedOutput <- require (Output.mkOutput address (Amount.lovelace 9) (Datum.DatumHash hashed) Nothing)
  let resolved = [Utxo.utxo (Input.input txId 1) output, Utxo.utxo (Input.input txId 2) hashedOutput]
      reference =
        [ object ["txId" .= TxId.toHex txId, "index" .= (1 :: Int)],
          object ["address" .= Address.toText address, "value" .= object ["coins" .= (42 :: Int), "assets" .= object [Data.Aeson.Key.fromText (Policy.toHex policy <> ".ff") .= (7 :: Int)]], "datumHash" .= Null, "datum" .= Hex.encodeHex (Data.toCbor inline), "script" .= object ["plutus:v2" .= String "450100002499"]]
        ]
      hashReference =
        [ object ["txId" .= TxId.toHex txId, "index" .= (2 :: Int)],
          object ["address" .= Address.toText address, "value" .= object ["coins" .= (9 :: Int)], "datumHash" .= Hex.encodeHex (B.replicate 32 2), "datum" .= Null, "script" .= Null]
        ]
  Json.evaluationPayload tx resolved @?= Right (object ["cbor" .= Hex.encodeHex (Tx.encodeCbor tx), "additionalUtxoSet" .= [reference, hashReference]])
  assertBool "duplicate resolution" (isLeft (Json.evaluationPayload tx (resolved ++ resolved)))
  unsupportedTx <- transaction [Redeemer.Voting]
  assertBool "unsupported v5 purpose" (isLeft (Json.evaluationPayload unsupportedTx []))
  forM_ [Plutus.V3, Plutus.V4] $ \version -> do
    newer <- require (Plutus.fromBytes version (Plutus.toBytes script))
    witnesses <- require (Witnesses.mkWitnesses [] [] [Script.Plutus newer] [] [])
    assertBool "unsupported v5 script" (isLeft (Json.evaluationPayload (Tx.setWitnesses (Witnesses.fromWitnesses witnesses) tx) []))

require :: (Show failure) => Either failure value -> IO value
require = either (\failure -> assertFailure (show failure) >> fail "invalid JSON fixture") pure

-- Regression from a hosted preprod evaluation: the identical signed V2 mint
-- failed with value={coins:10000000,assets:{}} and succeeded after omitting only
-- assets. Absence retains the exact Ada-only value; payload above separately
-- checks that a nonempty policy/name map remains unchanged.
adaOnlyPayload :: IO ()
adaOnlyPayload = do
  tx <- transaction []
  identifier <- require (TxId.fromBytes (B.replicate 32 0xab))
  address <- fixtureAddress
  output <- require (Output.mkOutput address (Amount.lovelace 10000000) Datum.NoDatum Nothing)
  let supplemental = Utxo.utxo (Input.input identifier 0) output
      expected =
        [ object ["txId" .= TxId.toHex identifier, "index" .= (0 :: Int)],
          object ["address" .= Address.toText address, "value" .= object ["coins" .= (10000000 :: Int)], "datumHash" .= Null, "datum" .= Null, "script" .= Null]
        ]
  Json.evaluationPayload tx [supplemental] @?= Right (object ["cbor" .= Hex.encodeHex (Tx.encodeCbor tx), "additionalUtxoSet" .= [expected]])
