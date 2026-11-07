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

-- | Provider queries over an injectable, bounded HTTP transport. No operation
-- retries a POST or emits credential-bearing response/request diagnostics.
module Cometa.Provider.Blockfrost.Internal.Provider (providerWithTransport) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import Cometa.AssetId (AssetId (..))
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.Provider as Provider
import Cometa.Provider.Blockfrost.Internal.Config (Config)
import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import qualified Cometa.Provider.Blockfrost.Internal.Json as Json
import qualified Cometa.Provider.Blockfrost.Internal.Protocol as Protocol
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Amount
import Control.Concurrent (threadDelay)
import Control.Monad (foldM, unless, when)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Aeson (Value (..), encode, (.:))
import Data.Aeson.Types (Parser, withObject, withText)
import Data.ByteString (ByteString)
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

providerWithTransport :: Config -> Http.Transport -> Provider.Provider
providerWithTransport config transport =
  (Provider.unavailable ("Blockfrost " <> Text.pack (show (Config.network config))) (Config.networkMagic (Config.network config)))
    { Provider.protocolParameters = guarded transport "blockfrost.protocolParameters" $ runExceptT $ do
        value <- requiredJSON transport "blockfrost.protocolParameters" ["epochs", "latest", "parameters"] []
        except (Protocol.decodeProtocolParameters value),
      Provider.utxosAt = \address -> guarded transport "blockfrost.utxosAt" (atAddress transport "blockfrost.utxosAt" address Nothing),
      Provider.utxosWithAsset = \address asset -> guarded transport "blockfrost.utxosWithAsset" (atAddress transport "blockfrost.utxosWithAsset" address (Just asset)),
      Provider.utxoWithAsset = guarded transport "blockfrost.utxoWithAsset" . uniqueAsset transport,
      Provider.resolveInputs = guarded transport "blockfrost.resolveInputs" . resolve transport,
      Provider.resolveDatum = guarded transport "blockfrost.resolveDatum" . datum transport,
      Provider.rewardBalance = guarded transport "blockfrost.rewardBalance" . rewards transport,
      Provider.submitTransaction = guarded transport "blockfrost.submitTransaction" . submit transport,
      Provider.evaluateTransaction = \transaction inputs -> guarded transport "blockfrost.evaluateTransaction" (evaluate transport transaction inputs),
      Provider.awaitTransaction = \identifier timeout -> guarded transport "blockfrost.awaitTransaction" (await config transport identifier timeout)
    }

guarded :: Http.Transport -> Text -> IO (Either Error a) -> IO (Either Error a)
guarded transport operation action = do
  current <- Http.checkOpen transport
  case current of
    Left failure -> pure (Left (transportError operation failure))
    Right () -> action

transportError :: Text -> Http.HttpFailure -> Error
transportError operation failure = case failure of
  Http.Closed -> RuntimeClosed
  Http.Timeout -> ProviderTransportError operation "timeout"
  Http.ConnectionFailure -> ProviderTransportError operation "connection failure"
  Http.ResponseTooLarge -> ProviderTransportError operation "response too large"

getRequest :: [Text] -> [(Text, Text)] -> Http.Request
getRequest path query = Http.Request Http.Get path query "" "" Nothing

send :: Http.Transport -> Text -> Http.Request -> IO (Either Error Http.Response)
send transport operation request = either (Left . transportError operation) Right <$> Http.send transport request

getJSON :: Http.Transport -> Text -> [Text] -> [(Text, Text)] -> Bool -> IO (Either Error (Maybe Value))
getJSON transport operation path query missing = do
  result <- send transport operation (getRequest path query)
  pure $ do
    response <- result
    case Http.status response of
      200 -> Just <$> Json.decodeValue operation (Http.bodyBytes response)
      404 | missing -> Right Nothing
      code -> Left (ProviderHttpError operation code)

requiredJSON :: Http.Transport -> Text -> [Text] -> [(Text, Text)] -> ExceptT Error IO Value
requiredJSON transport operation path query = do
  value <- ExceptT (getJSON transport operation path query False)
  maybe (except (Left (InvalidProviderResponse operation))) pure value

-- Reject repeated identities rather than quietly truncate or retain conflicting
-- snapshots across pages. A fixed request bound prevents endless distinct pages.
pages :: Http.Transport -> Text -> [Text] -> IO (Either Error [Json.Row])
pages transport operation path = runExceptT (go 1 Set.empty [])
  where
    go page seen chunks = do
      when (page > 10000) (except (Left (InvalidProviderResponse operation)))
      response <- ExceptT (getJSON transport operation path [("count", "100"), ("page", Text.pack (show page)), ("order", "asc")] (page == (1 :: Int)))
      current <- maybe (pure []) (except . Json.parseValue operation Json.rows) response
      let identities = map Json.rowInput current
      unless (length current <= 100 && Set.size (Set.fromList identities) == length identities && all (`Set.notMember` seen) identities) (except (Left (InvalidProviderResponse operation)))
      let completed = current : chunks
      if length current < 100
        then pure (concat (reverse completed))
        else go (page + 1) (Set.union seen (Set.fromList identities)) completed

atAddress :: Http.Transport -> Text -> Address.Address -> Maybe AssetId -> IO (Either Error [Utxo.Utxo])
atAddress transport operation address asset = runExceptT $ do
  let suffix = case asset of Just value@Native {} -> [Json.assetText value]; _ -> []
  found <- ExceptT (pages transport operation (["addresses", Address.toText address, "utxos"] <> suffix))
  unless (all ((== address) . Json.rowAddress) found) (except (Left (InvalidProviderResponse operation)))
  values <- ExceptT (materialize transport operation found)
  pure $ case asset of Nothing -> values; Just value -> filter ((> 0) . Amount.quantity value . Output.value . Utxo.output) values

uniqueAsset :: Http.Transport -> AssetId -> IO (Either Error (Maybe Utxo.Utxo))
uniqueAsset _ Ada = pure (Left (UnsupportedOperation "NFT lookup requires a native asset"))
uniqueAsset transport asset = runExceptT $ do
  found <- ExceptT (pages transport operation ["assets", Json.assetText asset, "utxos"])
  values <- ExceptT (materialize transport operation found)
  case values of
    [] -> pure Nothing
    [value] | Amount.quantity asset (Output.value (Utxo.output value)) == 1 -> pure (Just value)
    _ -> except (Left (InvalidProviderResponse operation))
  where
    operation = "blockfrost.utxoWithAsset"

materialize :: Http.Transport -> Text -> [Json.Row] -> IO (Either Error [Utxo.Utxo])
materialize transport operation found = runExceptT $ reverse . snd <$> foldM step (Map.empty, []) found
  where
    step (scripts, values) row = do
      case (Json.rowDatum row, Json.rowDatumHash row) of
        (Datum.InlineDatum encoded, Just expected) -> verifyDatum operation expected encoded
        _ -> pure ()
      (updated, script) <- case Json.rowScriptHash row of
        Nothing -> pure (scripts, Nothing)
        Just hash -> case Map.lookup hash scripts of
          Just known -> pure (scripts, Just known)
          Nothing -> do
            fetched <- fetchScript transport operation hash
            pure (Map.insert hash fetched scripts, Just fetched)
      output <- except (mapResponse operation (Output.mkOutput (Json.rowAddress row) (Json.rowValue row) (Json.rowDatum row) script))
      pure (updated, Utxo.utxo (Json.rowInput row) output : values)

mapResponse :: Text -> Either Error a -> Either Error a
mapResponse operation = either (const (Left (InvalidProviderResponse operation))) Right

fetchScript :: Http.Transport -> Text -> Credential.ScriptHash -> ExceptT Error IO Script.Script
fetchScript transport operation expected = do
  let path = ["scripts", Hex.encodeHex (Credential.scriptHashBytes expected)]
  metadata <- requiredJSON transport operation path []
  (hash, kind) <- except (Json.parseValue operation (withObject "script metadata" (\entry -> (,) <$> (entry .: "script_hash" >>= Json.parseHex) <*> entry .: "type")) metadata)
  unless (hash == Credential.scriptHashBytes expected) (except (Left (InvalidProviderResponse operation)))
  script <- case kind :: Text of
    "timelock" -> do
      payload <- requiredJSON transport operation (path <> ["json"]) []
      Script.Native <$> except (Json.parseValue operation (withObject "script JSON" (\entry -> entry .: "json" >>= Json.nativeScript)) payload)
    _ -> do
      version <- except $ case kind of
        "plutusV1" -> Right Plutus.V1
        "plutusV2" -> Right Plutus.V2
        "plutusV3" -> Right Plutus.V3
        _ -> Left (UnsupportedOperation "Blockfrost returned an unsupported reference script language")
      payload <- requiredJSON transport operation (path <> ["cbor"]) []
      bytes <- except (Json.parseValue operation cborField payload)
      Script.Plutus <$> except (mapResponse operation (Plutus.fromBytes version bytes))
  actual <- ExceptT (Script.hash script)
  unless (actual == expected) (except (Left (InvalidProviderResponse operation)))
  pure script

cborField :: Value -> Parser ByteString
cborField = withObject "CBOR response" (\entry -> entry .: "cbor" >>= Json.parseHex)

verifyDatum :: Text -> Datum.Hash32 -> Data.EncodedPlutusData -> ExceptT Error IO ()
verifyDatum operation expected encoded = do
  actual <- ExceptT (Data.hash encoded)
  unless (Blake2b.toBytes actual == Datum.hashBytes expected) (except (Left (InvalidProviderResponse operation)))

datum :: Http.Transport -> Datum.Hash32 -> IO (Either Error (Maybe Data.EncodedPlutusData))
datum transport hash = runExceptT $ do
  response <- ExceptT (getJSON transport operation ["scripts", "datum", Hex.encodeHex (Datum.hashBytes hash), "cbor"] [] True)
  case response of
    Nothing -> pure Nothing
    Just value -> do
      bytes <- except (Json.parseValue operation cborField value)
      encoded <- except (mapResponse operation (Data.decodeCbor bytes))
      verifyDatum operation hash encoded
      pure (Just encoded)
  where
    operation = "blockfrost.resolveDatum"

rewards :: Http.Transport -> Reward.RewardAddress -> IO (Either Error Word64)
rewards transport account = runExceptT $ do
  response <- ExceptT (getJSON transport operation ["accounts", Reward.toText account] [] True)
  maybe (pure 0) (except . Json.parseValue operation parser) response
  where
    operation = "blockfrost.rewardBalance"
    parser = withObject "reward account" $ \entry -> do
      text <- entry .: "stake_address"
      actual <- either (const (fail "Invalid reward account")) pure (Reward.fromText text)
      unless (actual == account) (fail "Account identity mismatch")
      entry .: "withdrawable_amount" >>= Json.parseQuantity

-- Historical tx outputs alone do not establish spendability. Cross-check each
-- discovered address through the current UTxO endpoint, then return only the
-- requested identities in first-request order. These observations are not atomic.
resolve :: Http.Transport -> [Input.Input] -> IO (Either Error [Utxo.Utxo])
resolve transport requested = runExceptT $ do
  let unique = distinct requested
      transactionIds = distinct (map Input.transactionId unique)
  discovered <- concat <$> traverse discover transactionIds
  let addresses = distinct (map snd discovered)
      eligible = Set.fromList (map fst discovered)
  snapshots <- traverse (\address -> ExceptT (atAddress transport operation address Nothing)) addresses
  let found = Map.fromList [(Utxo.input value, value) | value <- concat snapshots, Set.member (Utxo.input value) eligible]
  pure (mapMaybe (`Map.lookup` found) unique)
  where
    operation = "blockfrost.resolveInputs"
    discover transaction = do
      response <- ExceptT (getJSON transport operation ["txs", TxId.toHex transaction, "utxos"] [] True)
      entries <- maybe (pure []) (except . Json.parseValue operation (Json.transactionAddresses transaction)) response
      pure [(reference, address) | (reference, address) <- entries, reference `elem` requested]

distinct :: (Ord a) => [a] -> [a]
distinct = go Set.empty
  where
    go _ [] = []
    go seen (value : rest)
      | Set.member value seen = go seen rest
      | otherwise = value : go (Set.insert value seen) rest

submit :: Http.Transport -> Tx.Transaction -> IO (Either Error TxId.TransactionId)
submit transport transaction = runExceptT $ do
  expected <- ExceptT (Tx.transactionId transaction)
  response <- ExceptT (send transport operation (Http.Request Http.Post ["tx", "submit"] [] (Tx.encodeCbor transaction) "application/cbor" Nothing))
  unless (Http.status response == 200) (except (Left (ProviderHttpError operation (Http.status response))))
  value <- except (Json.decodeValue operation (Http.bodyBytes response))
  identifier <- except (Json.parseValue operation (withText "transaction hash" (either (const (fail "Invalid transaction hash")) pure . TxId.fromHex)) value)
  unless (identifier == expected) (except (Left (InvalidProviderResponse operation)))
  pure identifier
  where
    operation = "blockfrost.submitTransaction"

evaluate :: Http.Transport -> Tx.Transaction -> [Utxo.Utxo] -> IO (Either Error Evaluation.Budgets)
evaluate transport transaction inputs = runExceptT $ do
  payload <- except (Json.evaluationPayload transaction inputs)
  response <- ExceptT (send transport operation (Http.Request Http.Post ["utils", "txs", "evaluate", "utxos"] [("version", "5")] (Lazy.toStrict (encode payload)) "application/json" Nothing))
  unless (Http.status response == 200) (except (Left (ProviderHttpError operation (Http.status response))))
  value <- except (Json.decodeValue operation (Http.bodyBytes response))
  except (Json.decodeBudgets transaction value)
  where
    operation = "blockfrost.evaluateTransaction"

await :: Config -> Http.Transport -> TxId.TransactionId -> Word64 -> IO (Either Error Bool)
await _ _ _ 0 = pure (Right False)
await config transport identifier milliseconds = do
  started <- getMonotonicTimeNSec
  loop (toInteger started + toInteger milliseconds * 1000000)
  where
    operation = "blockfrost.awaitTransaction"
    loop deadline = do
      now <- toInteger <$> getMonotonicTimeNSec
      if now >= deadline
        then pure (Right False)
        else do
          let remaining = max 1 ((deadline - now + 999999) `div` 1000000)
              request = (getRequest ["txs", TxId.toHex identifier] []) {Http.requestTimeoutMillis = Just (fromInteger (min remaining (toInteger (Config.responseTimeoutMillis config))))}
          result <- send transport operation request
          case result of
            Left failure -> do
              finished <- toInteger <$> getMonotonicTimeNSec
              pure $ if finished >= deadline && failure == ProviderTransportError operation "timeout" then Right False else Left failure
            Right response -> case Http.status response of
              200 -> pure $ do
                value <- Json.decodeValue operation (Http.bodyBytes response)
                Json.parseValue operation confirmed value
                pure True
              404 -> do
                finished <- toInteger <$> getMonotonicTimeNSec
                let delay = min (toInteger (Config.pollIntervalMillis config) * 1000) (max 0 ((deadline - finished) `div` 1000))
                when (delay > 0) (threadDelay (fromInteger delay))
                loop deadline
              code -> pure (Left (ProviderHttpError operation code))
    confirmed = withObject "confirmed transaction" $ \entry -> do
      text <- entry .: "hash"
      actual <- either (const (fail "Invalid transaction hash")) pure (TxId.fromHex text)
      unless (actual == identifier) (fail "Transaction identity mismatch")
      block <- entry .: "block" >>= Json.parseHex
      unless (B.length block == 32) (fail "Invalid block hash")
      _ <- entry .: "block_height" >>= Json.parseNatural
      pure ()
