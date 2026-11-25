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

-- | Backend operations over injected scoped transports. Authentication belongs
-- to the transport; error values never contain URLs, headers or response bodies.
module Cometa.Provider.Internal.Remote (Backend (..), provider, parse, transportError, request, jsonRequest, json) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import Cometa.AssetId (AssetId (..))
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import qualified Cometa.Provider.Blockfrost.Internal.Json as Json
import qualified Cometa.Provider.Internal.Codec as C
import qualified Cometa.Provider.Internal.Protocol as Protocol
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Amount
import Control.Concurrent (threadDelay)
import Control.Monad (unless, when, (>=>))
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Aeson (Value (..), encode, object, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, withObject)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)

-- DEFINITIONS ----------------------------------------------------------------

data Backend = Koios | Kupmios deriving (Eq, Show)

data Service = Service !Backend !Config.Config !Http.Transport !Http.Transport

provider :: Backend -> Config.Config -> Http.Transport -> Http.Transport -> Provider.Provider
provider backend config indexer node =
  (Provider.unavailable (Text.pack (show backend)) (Config.networkMagic (Config.network config)))
    { Provider.protocolParameters = run $ do
        response <- rpc service "queryLedgerState/protocolParameters" (object [])
        except (Protocol.decodeParameters response),
      Provider.utxosAt = run . atAddress service,
      Provider.utxosWithAsset = \address asset -> run (filter ((> 0) . Amount.quantity asset . Output.value . Utxo.output) <$> atAddress service address),
      Provider.utxoWithAsset = run . nft service,
      Provider.resolveInputs = run . resolve service,
      Provider.resolveDatum = run . resolveDatum service,
      Provider.rewardBalance = run . rewards service,
      Provider.submitTransaction = run . submit service,
      Provider.evaluateTransaction = \transaction inputs -> run $ do
        payload <- except (C.evaluationPayload transaction inputs)
        response <- rpc service "evaluateTransaction" payload
        except (C.budgets transaction response),
      Provider.awaitTransaction = \tx timeout -> run (await service tx timeout)
    }
  where
    service = Service backend config indexer node
    -- Check both scopes even for operations that can return without HTTP.
    run action = runExceptT $ do
      ExceptT (fmap (either (Left . transportError) Right) (Http.checkOpen indexer))
      ExceptT (fmap (either (Left . transportError) Right) (Http.checkOpen node))
      action

parse :: (Value -> Parser a) -> Value -> ExceptT Error IO a
parse parser = except . C.parse parser

invalid :: ExceptT Error IO a
invalid = throwE (InvalidProviderResponse "provider.response")

transportError :: Http.HttpFailure -> Error
transportError failure = case failure of
  Http.Closed -> RuntimeClosed
  Http.Timeout -> ProviderTransportError "provider.request" "timeout"
  Http.ConnectionFailure -> ProviderTransportError "provider.request" "connection failure"
  Http.ResponseTooLarge -> ProviderTransportError "provider.request" "response too large"

request :: Http.Transport -> Http.Request -> ExceptT Error IO Http.Response
request transport value = ExceptT (fmap (either (Left . transportError) Right) (Http.send transport value))

jsonRequest :: Http.Method -> [Text] -> [(Text, Text)] -> Maybe Value -> Http.Request
jsonRequest method path query payload = Http.Request method path query (maybe B.empty (Lazy.toStrict . encode) payload) (maybe B.empty (const "application/json") payload) Nothing

json :: Http.Transport -> Http.Request -> Bool -> ExceptT Error IO (Maybe Value)
json transport req missing = do
  response <- request transport req
  case Http.status response of
    200 -> Just <$> except (Json.decodeValue "provider.response" (Http.bodyBytes response))
    404 | missing -> pure Nothing
    code -> throwE (ProviderHttpError "provider.request" code)

get :: Service -> [Text] -> [(Text, Text)] -> ExceptT Error IO Value
get (Service _ _ transport _) path query = json transport (jsonRequest Http.Get path query Nothing) False >>= maybe invalid pure

post :: Service -> [Text] -> [(Text, Text)] -> Value -> ExceptT Error IO Value
post (Service _ _ transport _) path query payload = json transport (jsonRequest Http.Post path query (Just payload)) False >>= maybe invalid pure

rpc :: Service -> Text -> Value -> ExceptT Error IO Value
rpc (Service backend _ _ node) method params = do
  -- Each request has an independent HTTP response; a constant correlation ID
  -- is sufficient and avoids shared mutable state across concurrent calls.
  response <- json node (jsonRequest Http.Post ["ogmios" | backend == Koios] [] (Just (object ["jsonrpc" .= ("2.0" :: Text), "id" .= ("cometa" :: Text), "method" .= method, "params" .= params]))) False >>= maybe invalid pure
  parse
    ( withObject "RPC response" $ \entry -> do
        version <- entry .: "jsonrpc"
        identifier <- entry .: "id"
        replyMethod <- entry .:? "method"
        unless (version == ("2.0" :: Text) && identifier == ("cometa" :: Text) && maybe True (== method) replyMethod && not (KM.member "error" entry)) (fail "RPC failure")
        entry .: "result"
    )
    response

-- Offset iteration has a finite page bound; output identities are checked below.
pages :: Service -> [Text] -> [(Text, Text)] -> Maybe Value -> ExceptT Error IO [Value]
pages service path query payload = go 0 []
  where
    go count chunks = do
      when (count >= (10000 :: Int)) invalid
      let pagination = [("limit", "100"), ("offset", Text.pack (show (count * 100))), ("order", "tx_hash.asc,tx_index.asc")]
      response <- maybe (get service path (query <> pagination)) (post service path (query <> pagination)) payload
      rows <- parse C.list response
      when (length rows > 100) invalid
      let completed = rows : chunks
      if length rows < 100 then pure (concat (reverse completed)) else go (count + 1) completed

outputs :: Service -> [Text] -> [(Text, Text)] -> Maybe Value -> ExceptT Error IO [Utxo.Utxo]
outputs service@(Service backend _ _ _) path query payload = do
  rows <- if backend == Kupmios then get service path query >>= parse C.list else pages service path query payload
  live <- if backend == Koios then filterMUnspent rows else pure rows
  values <- traverse convert live
  except (C.unique (map Utxo.input values))
  pure values
  where
    convert value = case backend of Koios -> C.koiosOutput value; Kupmios -> kupoOutput service value
    filterMUnspent rows = do
      pairs <- traverse (\row -> (,) row <$> parse (withObject "UTxO" (.: "is_spent")) row) rows
      pure [row | (row, False) <- pairs]

atAddress :: Service -> Address.Address -> ExceptT Error IO [Utxo.Utxo]
atAddress service@(Service backend _ _ _) address = do
  values <- case backend of
    Koios -> outputs service ["address_utxos"] [] (Just (object ["_addresses" .= [text], "_extended" .= True]))
    Kupmios -> outputs service ["matches", text] [("unspent", "")] Nothing
  unless (all ((== address) . Output.address . Utxo.output) values) invalid
  pure values
  where
    text = Address.toText address

nft :: Service -> AssetId -> ExceptT Error IO (Maybe Utxo.Utxo)
nft _ Ada = throwE (UnsupportedOperation "NFT lookup requires a native asset")
nft service@(Service backend _ _ _) asset = do
  values <- case backend of
    Koios -> outputs service ["asset_utxos"] [] (Just (object ["_asset_list" .= [[policy, name]], "_extended" .= True]))
    Kupmios -> outputs service ["matches", "*"] [("unspent", ""), ("policy_id", policy), ("asset_name", name)] Nothing
  case values of
    [] -> pure Nothing
    [value] | Amount.quantity asset (Output.value (Utxo.output value)) == 1 -> pure (Just value)
    _ -> invalid
  where
    unit = Json.assetText asset
    (policy, name) = Text.splitAt 56 unit

resolve :: Service -> [Input.Input] -> ExceptT Error IO [Utxo.Utxo]
resolve service@(Service backend _ _ _) requested = do
  found <- concat <$> traverse batch (chunks (distinct requested))
  except (C.unique (map Utxo.input found))
  unless (all ((`elem` requested) . Utxo.input) found) invalid
  let table = Map.fromList [(Utxo.input value, value) | value <- found]
  pure (mapMaybe (`Map.lookup` table) (distinct requested))
  where
    batch references = case backend of
      Koios -> outputs service ["utxo_info"] [] (Just (object ["_utxo_refs" .= map C.inputText references, "_extended" .= True]))
      Kupmios -> concat <$> traverse (\ref -> outputs service ["matches", Text.pack (show (Input.index ref)) <> "@" <> TxId.toHex (Input.transactionId ref)] [("unspent", "")] Nothing) references
    chunks [] = []
    chunks values = take 100 values : chunks (drop 100 values)

-- Preserve first-request order when callers repeat input references.
distinct :: (Ord a) => [a] -> [a]
distinct = go Set.empty
  where
    go _ [] = []; go seen (x : xs) | Set.member x seen = go seen xs | otherwise = x : go (Set.insert x seen) xs

resolveDatum :: Service -> Datum.Hash32 -> ExceptT Error IO (Maybe Data.EncodedPlutusData)
resolveDatum service@(Service backend _ transport _) hash = do
  bytes <- case backend of
    Koios -> do
      response <- post service ["datum_info"] [] (object ["_datum_hashes" .= [text]]) >>= parse C.list
      case response of
        [] -> pure Nothing
        [row] -> Just <$> parse (withObject "datum" (\o -> do actual <- o .: "datum_hash"; unless (actual == text) (fail "Datum mismatch"); o .: "bytes")) row
        _ -> invalid
    Kupmios -> do
      response <- json transport (jsonRequest Http.Get ["datums", text] [] Nothing) True
      case response of Nothing -> pure Nothing; Just Null -> pure Nothing; Just row -> Just <$> parse (withObject "datum" (.: "datum")) row
  traverse (C.datum hash) bytes
  where
    text = Hex.encodeHex (Datum.hashBytes hash)

kupoOutput :: Service -> Value -> ExceptT Error IO Utxo.Utxo
kupoOutput service row = do
  (reference, address, amount, hash, kind, scriptHash) <- parse parser row
  dat <- case (hash, kind) of
    (Nothing, Nothing) -> pure Datum.NoDatum
    (Just expected, Just "hash") -> pure (Datum.DatumHash expected)
    (Just expected, Just "inline") -> resolveDatum service expected >>= maybe invalid (pure . Datum.InlineDatum)
    _ -> invalid
  script <- traverse fetchScript scriptHash
  output <- except (Output.mkOutput address amount dat script)
  pure (Utxo.utxo reference output)
  where
    parser = withObject "Kupo output" $ \o -> do
      spent <- o .: "spent_at"
      unless (spent == Null) (fail "Spent output")
      reference <- C.input "transaction_id" "output_index" (Object o)
      address <- o .: "address" >>= C.checked . Address.fromText
      amount <-
        o .: "value"
          >>= withObject
            "value"
            ( \v -> do
                coins <- v .: "coins" >>= C.natural
                assets <- v .: "assets" >>= withObject "assets" (traverse asset . KM.toList)
                C.checked (C.unique (map fst assets))
                pure (Amount.lovelace (toInteger coins) <> foldMap (uncurry Amount.singleton) assets)
            )
      hash <- o .:? "datum_hash" >>= traverse (Json.parseHex >=> C.checked . Datum.hashFromBytes)
      kind <- o .:? "datum_type"
      scriptHash <- o .:? "script_hash"
      pure (reference, address, amount, hash, kind :: Maybe Text, scriptHash)
    asset (key, value) = do
      let text = Key.toText key
          (policy, suffix) = Text.splitAt 56 text
      name <- case Text.uncons suffix of Nothing -> pure ""; Just ('.', rest) -> pure rest; _ -> fail "Invalid Kupo asset"
      identifier <- Json.parseAsset (policy <> name)
      quantity <- C.natural value
      when (quantity == 0) (fail "Zero asset quantity")
      pure (identifier, toInteger quantity)
    fetchScript expected = do
      response <- get service ["scripts", expected] []
      (language, bytes) <- parse (withObject "script" (\s -> (,) <$> s .: "language" <*> s .: "script")) response
      C.script language (Just bytes) Nothing expected

rewards :: Service -> Reward.RewardAddress -> ExceptT Error IO Word64
rewards service@(Service backend _ _ _) account = case backend of
  Koios -> do
    rows <- post service ["account_info"] [] (object ["_stake_addresses" .= [text]]) >>= parse C.list
    case rows of [] -> pure 0; [row] -> parse reward row; _ -> invalid
  Kupmios -> do
    let (kind, key, hash) = case Reward.credential account of
          Credential.KeyCredential credential -> ("verificationKey", "keys", Credential.keyHashBytes credential)
          Credential.ScriptCredential credential -> ("script", "scripts", Credential.scriptHashBytes credential)
        hex = Hex.encodeHex hash
    rows <- rpc service "queryLedgerState/rewardAccountSummaries" (object [Key.fromText key .= [hex]]) >>= parse C.list
    case rows of
      [] -> pure 0
      [row] ->
        parse
          ( withObject
              "rewards"
              ( \o -> do
                  actual <- o .: "credential"
                  from <- o .: "from"
                  unless (actual == hex && from == (kind :: Text)) (fail "Reward identity mismatch")
                  o .: "rewards" >>= C.field "ada" >>= C.field "lovelace" >>= C.natural
              )
          )
          row
      _ -> invalid
  where
    text = Reward.toText account
    reward = withObject "reward account" $ \o -> do
      actual <- o .: "stake_address"
      unless (actual == text) (fail "Reward account mismatch")
      o .: "rewards_available" >>= C.natural

submit :: Service -> Tx.Transaction -> ExceptT Error IO TxId.TransactionId
submit service transaction = do
  expected <- ExceptT (Tx.transactionId transaction)
  response <- rpc service "submitTransaction" (object ["transaction" .= object ["cbor" .= Hex.encodeHex (Tx.encodeCbor transaction)]])
  actual <- parse (C.field "transaction" >=> withObject "transaction" (\o -> o .: "id" >>= C.checked . TxId.fromHex)) response
  unless (actual == expected) invalid
  pure expected

await :: Service -> TxId.TransactionId -> Word64 -> ExceptT Error IO Bool
await _ _ 0 = pure False
await service@(Service _ config _ _) identifier milliseconds = ExceptT $ do
  start <- toInteger <$> getMonotonicTimeNSec
  loop (start + toInteger milliseconds * 1000000)
  where
    loop deadline = do
      now <- toInteger <$> getMonotonicTimeNSec
      if now >= deadline
        then pure (Right False)
        else do
          let remaining = fromInteger (min (toInteger (Config.responseTimeoutMillis config)) ((deadline - now + 999999) `div` 1000000))
          result <- runExceptT (confirmed service identifier remaining)
          finished <- toInteger <$> getMonotonicTimeNSec
          case result of
            Left failure | finished >= deadline && failure == transportError Http.Timeout -> pure (Right False)
            Left failure -> pure (Left failure)
            Right True -> pure (Right (finished <= deadline))
            Right False -> do
              let delay = min (toInteger (Config.pollIntervalMillis config) * 1000) (max 0 ((deadline - finished) `div` 1000))
              when (delay > 0) (threadDelay (fromInteger delay))
              loop deadline

confirmed :: Service -> TxId.TransactionId -> Int -> ExceptT Error IO Bool
confirmed (Service backend _ transport _) identifier remaining = do
  let hash = TxId.toHex identifier
      base = case backend of
        Koios -> jsonRequest Http.Post ["tx_status"] [] (Just (object ["_tx_hashes" .= [hash]]))
        Kupmios -> jsonRequest Http.Get ["matches", "*@" <> hash] [] Nothing
  response <- json transport (base {Http.requestTimeoutMillis = Just remaining}) False
  case response of
    Nothing -> pure False
    Just value -> case backend of
      Koios -> do
        rows <- parse C.list value
        case rows of
          [] -> pure False
          [row] -> parse (withObject "status" (\o -> do actual <- o .: "tx_hash"; unless (actual == hash) (fail "Transaction mismatch"); confirmations <- o .: "num_confirmations"; if confirmations == Null then pure False else (> 0) <$> C.natural confirmations)) row
          _ -> invalid
      Kupmios -> do
        rows <- parse C.list value
        checks <-
          traverse
            ( parse
                ( withObject
                    "match"
                    ( \o -> do
                        actual <- o .: "transaction_id"
                        unless (actual == hash) (fail "Transaction mismatch")
                        o .: "created_at"
                          >>= withObject
                            "block"
                            ( \b -> do
                                _ <- b .: "slot_no" >>= C.natural
                                block <- b .: "header_hash" >>= Json.parseHex
                                unless (B.length block == 32) (fail "Invalid block")
                                pure True
                            )
                    )
                )
            )
            rows
        pure (or checks)
