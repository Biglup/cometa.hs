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
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Scripted official endpoint fixtures; no credentials or network access.
module BlockfrostProvider (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import Cometa.AssetId (AssetId (..))
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost as Blockfrost
import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import Cometa.Provider.Blockfrost.Internal.Provider (providerWithTransport)
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
import Control.Concurrent (threadDelay)
import Control.Monad (forM_, unless, (>=>))
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))

-- TYPES ----------------------------------------------------------------------

data Step = Step (Http.Request -> Assertion) (Either Http.HttpFailure Http.Response)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Blockfrost provider queries"
    [ testCase "all address pages preserve order and exact pagination parameters" pagination,
      testCase "duplicate pages and mismatched address snapshots fail" invalidPages,
      testCase "missing results and status failures have endpoint-specific meanings" statuses,
      testCase "native assets and lovelace use the appropriate endpoints" assets,
      testCase "NFT lookup rejects ambiguous quantity and multiple outputs" nfts,
      testCase "resolution excludes historical spent outputs and preserves request order" resolution,
      testCase "datum lookup verifies exact CBOR against its hash" datums,
      testCase "reference scripts are cached per query and their hashes verified" scripts,
      testCase "submission sends exact CBOR once and validates the accepted hash" submission,
      testCase "remote evaluation sends v5 additional inputs and exact budgets" evaluation,
      testCase "confirmation uses identities, monotonic deadlines and cancellation" confirmation,
      testCase "escaped providers reject even empty operations" closed
    ]

must :: (Show error) => Either error value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

configuration :: IO Config.Config
configuration = Config.defaultConfig Config.Preview <$> must (Config.mkProjectId "preview-fixture-not-a-real-project")

address :: IO Address.Address
address = do
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  pure (Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key)))

identifier :: IO TxId.TransactionId
identifier = must (TxId.fromBytes (B.replicate 32 8))

row :: Address.Address -> TxId.TransactionId -> Word64 -> Value
row destination tx index =
  object
    [ "address" .= Address.toText destination,
      "tx_hash" .= TxId.toHex tx,
      "output_index" .= index,
      "amount" .= [object ["unit" .= ("lovelace" :: Text), "quantity" .= ("2000000" :: Text)]],
      "data_hash" .= Null,
      "inline_datum" .= Null,
      "reference_script_hash" .= Null
    ]

set :: Text -> Value -> Value -> Value
set key value (Object fields) = Object (KeyMap.insert (Key.fromText key) value fields)
set _ _ value = value

reply :: Int -> Value -> Either Http.HttpFailure Http.Response
reply status value = Right (Http.Response status (Lazy.toStrict (encode value)) Nothing)

get :: [Text] -> Http.Request -> Assertion
get path request = do
  Http.method request @?= Http.Get
  Http.path request @?= path
  Http.body request @?= B.empty

scripted :: [Step] -> (Provider.Provider -> IO ()) -> IO ()
scripted responses action = do
  baseConfig <- configuration
  let config = baseConfig {Config.pollIntervalMillis = 1}
  pending <- newIORef responses
  let send request = do
        next <- atomicModifyIORef' pending $ \case [] -> ([], Nothing); step : rest -> (rest, Just step)
        case next of
          Nothing -> assertFailure "Unexpected additional HTTP request" >> pure (Left Http.ConnectionFailure)
          Just (Step check response) -> check request >> pure response
      transport = Http.Transport send (pure (Right ()))
  action (providerWithTransport config transport)
  remaining <- readIORef pending
  unless (null remaining) (assertFailure "Expected HTTP requests were not made")

pagination :: IO ()
pagination = do
  destination <- address
  tx <- identifier
  let path = ["addresses", Address.toText destination, "utxos"]
      check page request = do
        get path request
        Http.query request @?= [("count", "100"), ("page", page), ("order", "asc")]
  scripted [Step (check "1") (reply 200 (toJSONRows [row destination tx index | index <- [0 .. 99]])), Step (check "2") (reply 200 (toJSONRows [row destination tx 100]))] $ \provider -> do
    found <- Provider.utxosAt provider destination >>= must
    map (Input.index . Utxo.input) found @?= [0 .. 100]

toJSONRows :: [Value] -> Value
toJSONRows = toJSON

invalidPages :: IO ()
invalidPages = do
  destination <- address
  tx <- identifier
  let first = toJSONRows [row destination tx index | index <- [0 .. 99]]
      expected = Left (InvalidProviderResponse "blockfrost.utxosAt")
  scripted [Step (const (pure ())) (reply 200 first), Step (const (pure ())) (reply 200 first)] $ \provider -> Provider.utxosAt provider destination >>= (@?= expected)
  wrongKey <- must (Credential.keyHashFromBytes (B.replicate 28 9))
  let wrong = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential wrongKey))
  scripted [Step (const (pure ())) (reply 200 (toJSONRows [row wrong tx 0]))] $ \provider -> Provider.utxosAt provider destination >>= (@?= expected)

statuses :: IO ()
statuses = do
  destination <- address
  tx <- identifier
  hash <- must (Datum.hashFromBytes (B.replicate 32 0))
  stake <- must (Credential.keyHashFromBytes (B.replicate 28 9))
  let account = Reward.fromCredential Network.testnet (Credential.KeyCredential stake)
  scripted (replicate 4 (Step (const (pure ())) (reply 404 Null))) $ \provider -> do
    Provider.utxosAt provider destination >>= (@?= Right [])
    Provider.resolveDatum provider hash >>= (@?= Right Nothing)
    Provider.rewardBalance provider account >>= (@?= Right 0)
    Provider.resolveInputs provider [Input.input tx 0] >>= (@?= Right [])
  scripted [Step (const (pure ())) (reply 200 (object ["stake_address" .= Text.toUpper (Reward.toText account), "withdrawable_amount" .= ("20" :: Text)]))] $ \provider -> Provider.rewardBalance provider account >>= (@?= Right 20)
  forM_ [400, 403, 418, 425, 429, 500] $ \status ->
    scripted [Step (const (pure ())) (reply status (object ["message" .= ("redacted fixture" :: Text)]))] $ \provider ->
      Provider.utxosAt provider destination >>= (@?= Left (ProviderHttpError "blockfrost.utxosAt" status))
  scripted [Step (const (pure ())) (reply 404 Null)] (Provider.protocolParameters >=> (@?= Left (ProviderHttpError "blockfrost.protocolParameters" 404)))
  scripted [Step (const (pure ())) (Right (Http.Response 200 "not json" Nothing))] $ \provider -> Provider.utxosAt provider destination >>= (@?= Left (InvalidProviderResponse "blockfrost.utxosAt"))

asset :: IO AssetId
asset = Native <$> must (Policy.fromBytes (B.replicate 28 1)) <*> pure AssetName.empty

assetRow :: Address.Address -> TxId.TransactionId -> Word64 -> AssetId -> Text -> Value
assetRow destination tx index token quantity =
  set "amount" (toJSON [object ["unit" .= ("lovelace" :: Text), "quantity" .= ("2000000" :: Text)], object ["unit" .= unit, "quantity" .= quantity]]) (row destination tx index)
  where
    unit = case token of Ada -> "lovelace"; Native policy name -> Policy.toHex policy <> AssetName.toHex name

assets :: IO ()
assets = do
  destination <- address
  tx <- identifier
  token <- asset
  let path = ["addresses", Address.toText destination, "utxos"]
      unit = case token of Ada -> "lovelace"; Native policy name -> Policy.toHex policy <> AssetName.toHex name
  scripted [Step (get path) (reply 200 (toJSONRows [row destination tx 0])), Step (get (path <> [unit])) (reply 200 (toJSONRows [assetRow destination tx 0 token "1"]))] $ \provider -> do
    ada <- Provider.utxosWithAsset provider destination Ada >>= must
    length ada @?= 1
    native <- Provider.utxosWithAsset provider destination token >>= must
    map (Amount.quantity token . Output.value . Utxo.output) native @?= [1]

nfts :: IO ()
nfts = do
  destination <- address
  tx <- identifier
  token <- asset
  scripted [Step (const (pure ())) (reply 200 (toJSONRows [assetRow destination tx 0 token "1"]))] $ \provider -> do
    found <- Provider.utxoWithAsset provider token >>= must
    fmap (Amount.quantity token . Output.value . Utxo.output) found @?= Just 1
  forM_ [[assetRow destination tx 0 token "2"], [assetRow destination tx 0 token "1", assetRow destination tx 1 token "1"]] $ \values ->
    scripted [Step (const (pure ())) (reply 200 (toJSONRows values))] $ \provider -> Provider.utxoWithAsset provider token >>= (@?= Left (InvalidProviderResponse "blockfrost.utxoWithAsset"))
  scripted [Step (const (pure ())) (reply 404 Null)] $ \provider -> Provider.utxoWithAsset provider token >>= (@?= Right Nothing)

resolution :: IO ()
resolution = do
  destination <- address
  tx <- identifier
  missing <- must (TxId.fromBytes (B.replicate 32 9))
  let historical = object ["hash" .= TxId.toHex tx, "inputs" .= ([] :: [Value]), "outputs" .= [row destination tx 0, row destination tx 1]]
  scripted [Step (get ["txs", TxId.toHex tx, "utxos"]) (reply 200 historical), Step (get ["txs", TxId.toHex missing, "utxos"]) (reply 404 Null), Step (get ["addresses", Address.toText destination, "utxos"]) (reply 200 (toJSONRows [row destination tx 1]))] $ \provider -> do
    found <- Provider.resolveInputs provider [Input.input tx 1, Input.input tx 0, Input.input tx 1, Input.input missing 0] >>= must
    map Utxo.input found @?= [Input.input tx 1]
  let consumed = object ["hash" .= TxId.toHex tx, "inputs" .= ([] :: [Value]), "outputs" .= [set "consumed_by_tx" (String (TxId.toHex missing)) (row destination tx 0), row destination tx 1]]
  scripted [Step (const (pure ())) (reply 200 consumed), Step (const (pure ())) (reply 200 (toJSONRows [row destination tx 0, row destination tx 1]))] $ \provider -> do
    found <- Provider.resolveInputs provider [Input.input tx 0, Input.input tx 1] >>= must
    map Utxo.input found @?= [Input.input tx 1]

datums :: IO ()
datums = do
  let encoded = Data.fromData (Data.Integer 42)
  digest <- Data.hash encoded >>= must
  hash <- must (Datum.hashFromBytes (Blake2b.toBytes digest))
  let payload = object ["cbor" .= Hex.encodeHex (Data.toCbor encoded)]
  scripted [Step (get ["scripts", "datum", Hex.encodeHex (Datum.hashBytes hash), "cbor"]) (reply 200 payload)] $ \provider -> Provider.resolveDatum provider hash >>= (@?= Right (Just encoded))
  wrong <- must (Datum.hashFromBytes (B.replicate 32 0))
  scripted [Step (const (pure ())) (reply 200 payload)] $ \provider -> Provider.resolveDatum provider wrong >>= (@?= Left (InvalidProviderResponse "blockfrost.resolveDatum"))
  destination <- address
  tx <- identifier
  let inline = set "inline_datum" (String (Hex.encodeHex (Data.toCbor encoded))) (set "data_hash" (String (Hex.encodeHex (Datum.hashBytes wrong))) (row destination tx 0))
  scripted [Step (const (pure ())) (reply 200 (toJSONRows [inline]))] $ \provider -> Provider.utxosAt provider destination >>= (@?= Left (InvalidProviderResponse "blockfrost.utxosAt"))

scripts :: IO ()
scripts = do
  destination <- address
  tx <- identifier
  let script = Script.Native (Native.allOf [])
  hash <- Script.hash script >>= must
  let hashText = Hex.encodeHex (Credential.scriptHashBytes hash)
      referenced index = set "reference_script_hash" (String hashText) (row destination tx index)
      metadata = object ["script_hash" .= hashText, "type" .= ("timelock" :: Text), "serialised_size" .= Null]
      content = object ["json" .= object ["type" .= ("all" :: Text), "scripts" .= ([] :: [Value])]]
  scripted [Step (const (pure ())) (reply 200 (toJSONRows [referenced 0, referenced 1])), Step (get ["scripts", hashText]) (reply 200 metadata), Step (get ["scripts", hashText, "json"]) (reply 200 content)] $ \provider -> do
    found <- Provider.utxosAt provider destination >>= must
    map (Output.referenceScript . Utxo.output) found @?= [Just script, Just script]
  let wrong = object ["json" .= object ["type" .= ("any" :: Text), "scripts" .= ([] :: [Value])]]
  scripted [Step (const (pure ())) (reply 200 (toJSONRows [referenced 0])), Step (const (pure ())) (reply 200 metadata), Step (const (pure ())) (reply 200 wrong)] $ \provider -> Provider.utxosAt provider destination >>= (@?= Left (InvalidProviderResponse "blockfrost.utxosAt"))
  plutus <- must (Plutus.fromBytes Plutus.V2 (B.pack [0x44, 1, 2, 3, 4]))
  plutusHash <- Plutus.hash plutus >>= must
  let plutusText = Hex.encodeHex (Credential.scriptHashBytes plutusHash)
      locked = set "reference_script_hash" (String plutusText) (row destination tx 0)
  scripted [Step (const (pure ())) (reply 200 (toJSONRows [locked])), Step (const (pure ())) (reply 200 (object ["script_hash" .= plutusText, "type" .= ("plutusV2" :: Text)])), Step (const (pure ())) (reply 200 (object ["cbor" .= Hex.encodeHex (Plutus.toBytes plutus)]))] $ \provider -> do
    found <- Provider.utxosAt provider destination >>= must
    map (Output.referenceScript . Utxo.output) found @?= [Just (Script.Plutus plutus)]

transaction :: IO Tx.Transaction
transaction = do
  body <- must (Body.fromBody (Body.body [] [] 0))
  pure (Tx.assemble body (Witnesses.fromWitnesses Witnesses.empty) Nothing)

submission :: IO ()
submission = do
  tx <- transaction
  expected <- Tx.transactionId tx >>= must
  let check request = do
        Http.method request @?= Http.Post
        Http.path request @?= ["tx", "submit"]
        Http.contentType request @?= "application/cbor"
        Http.body request @?= Tx.encodeCbor tx
  scripted [Step check (reply 200 (String (TxId.toHex expected)))] $ \provider -> Provider.submitTransaction provider tx >>= (@?= Right expected)
  wrong <- identifier
  scripted [Step check (reply 200 (String (TxId.toHex wrong)))] $ \provider -> Provider.submitTransaction provider tx >>= (@?= Left (InvalidProviderResponse "blockfrost.submitTransaction"))
  scripted [Step check (reply 503 Null)] $ \provider -> Provider.submitTransaction provider tx >>= (@?= Left (ProviderHttpError "blockfrost.submitTransaction" 503))

evaluation :: IO ()
evaluation = do
  plain <- transaction
  let argument = Data.fromData (Data.Constr 0 [])
  witnesses <- must (Witnesses.mkWitnesses [] [] [] [] [Redeemer.Redeemer Redeemer.Minting 0 argument (ExUnits 0 0)])
  let tx = Tx.assemble (Tx.body plain) (Witnesses.fromWitnesses witnesses) Nothing
      response = object ["result" .= object ["EvaluationResult" .= object ["mint:0" .= object ["memory" .= (10 :: Int), "steps" .= (20 :: Int)]]]]
      check request = do
        Http.method request @?= Http.Post
        Http.query request @?= [("version", "5")]
        Http.contentType request @?= "application/json"
  expected <- must (Evaluation.mkBudgets [(Evaluation.RedeemerId Redeemer.Minting 0, ExUnits 10 20)])
  scripted [Step check (reply 200 response)] $ \provider -> Provider.evaluateTransaction provider tx [] >>= (@?= Right expected)
  scripted [Step check (reply 200 (object ["result" .= object ["EvaluationFailure" .= object []]]))] $ \provider -> Provider.evaluateTransaction provider tx [] >>= (@?= Left (InvalidEvaluationResult "Blockfrost script evaluation failed"))

confirmation :: IO ()
confirmation = do
  tx <- must (TxId.fromBytes (B.replicate 32 0xab))
  let success = object ["hash" .= Text.toUpper (TxId.toHex tx), "block" .= Text.replicate 64 "0", "block_height" .= (1 :: Int)]
  scripted [Step (get ["txs", TxId.toHex tx]) (reply 404 Null), Step (get ["txs", TxId.toHex tx]) (reply 200 success)] $ \provider -> Provider.awaitTransaction provider tx 1000 >>= (@?= Right True)
  scripted [] $ \provider -> Provider.awaitTransaction provider tx 0 >>= (@?= Right False)
  scripted [Step (const (pure ())) (reply 200 (set "hash" (String (Text.replicate 64 "0")) success))] $ \provider -> Provider.awaitTransaction provider tx 1000 >>= (@?= Left (InvalidProviderResponse "blockfrost.awaitTransaction"))
  config <- configuration
  let pending = providerWithTransport config {Config.pollIntervalMillis = 1} (Http.Transport (\_ -> pure (Right (Http.Response 404 "null" Nothing))) (pure (Right ())))
  Provider.awaitTransaction pending tx 3 >>= (@?= Right False)
  let failed = providerWithTransport config (Http.Transport (\_ -> pure (Left Http.Timeout)) (pure (Right ())))
  Provider.awaitTransaction failed tx 1000 >>= (@?= Left (ProviderTransportError "blockfrost.awaitTransaction" "timeout"))
  let slow = providerWithTransport config (Http.Transport (\_ -> threadDelay 1000000 >> pure (Left Http.Timeout)) (pure (Right ())))
  timeout 10000 (Provider.awaitTransaction slow tx 1000) >>= (@?= Nothing)

closed :: IO ()
closed = do
  config <- configuration
  escaped <- Blockfrost.withProvider config (pure . Right) >>= must
  tx <- identifier
  Provider.resolveInputs escaped [] >>= (@?= Left RuntimeClosed)
  Provider.awaitTransaction escaped tx 0 >>= (@?= Left RuntimeClosed)
