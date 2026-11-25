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

-- | Hydra's HTTP operations for an existing Conway Head. No L1 submission or
-- head-lifecycle command is issued by this provider.
module Cometa.Provider.Internal.Hydra (provider) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (..))
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import qualified Cometa.Provider.Blockfrost.Internal.Json as Json
import qualified Cometa.Provider.Internal.Codec as C
import qualified Cometa.Provider.Internal.Protocol as Protocol
import Cometa.Provider.Internal.Remote (json, jsonRequest, parse, request, transportError)
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Amount
import Control.Concurrent (threadDelay)
import Control.Monad (unless, when, (>=>))
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Aeson (Value (..), object, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, withObject)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)

-- DEFINITIONS ----------------------------------------------------------------

provider :: Config.Config -> Http.Transport -> Provider.Provider
provider config transport =
  (Provider.unavailable "Hydra" (Config.networkMagic (Config.network config)))
    { Provider.protocolParameters = run (get ["protocol-parameters"] >>= except . Protocol.decodeHydraParameters),
      Provider.utxosAt = \address -> run (filter ((== address) . Output.address . Utxo.output) <$> outputs),
      Provider.utxosWithAsset = \address asset -> run (filter (\u -> Output.address (Utxo.output u) == address && quantity asset u > 0) <$> outputs),
      Provider.utxoWithAsset = \asset -> run $ do
        when (asset == Ada) (throwE (UnsupportedOperation "NFT lookup requires a native asset"))
        found <- filter ((> 0) . quantity asset) <$> outputs
        case found of [] -> pure Nothing; [u] | quantity asset u == 1 -> pure (Just u); _ -> invalid,
      Provider.resolveInputs = \references -> run $ do
        values <- outputs
        let table = Map.fromList [(Utxo.input u, u) | u <- values]
        pure (mapMaybe (`Map.lookup` table) (distinct references)),
      Provider.resolveDatum = \hash -> run (outputs >>= findDatum hash),
      Provider.rewardBalance = \_ -> run (throwE (UnsupportedOperation "Hydra Heads do not support staking rewards")),
      Provider.evaluateTransaction = \_ _ -> run (throwE (UnsupportedOperation "Hydra has no remote evaluation endpoint; configure a local evaluator")),
      Provider.submitTransaction = run . submit transport,
      Provider.awaitTransaction = \identifier timeout -> run (await config transport identifier timeout)
    }
  where
    run action = runExceptT $ do
      ExceptT (fmap (either (Left . transportError) Right) (Http.checkOpen transport))
      action
    get path = json transport (jsonRequest Http.Get path [] Nothing) False >>= maybe invalid pure
    outputs = get ["snapshot", "utxo"] >>= parse (withObject "UTxO" (pure . KM.toList)) >>= traverse output
    quantity asset = Amount.quantity asset . Output.value . Utxo.output

invalid :: ExceptT Error IO a
invalid = throwE (InvalidProviderResponse "hydra.response")

distinct :: (Ord a) => [a] -> [a]
distinct = go Set.empty
  where
    go _ [] = []; go seen (x : xs) | Set.member x seen = go seen xs | otherwise = x : go (Set.insert x seen) xs

output :: (Key.Key, Value) -> ExceptT Error IO Utxo.Utxo
output (key, row) = do
  (reference, address, amount, hash, raw, inlineHash, inlinePresent, script) <- parse parser row
  dat <- case raw of
    Just bytes -> do
      when (isJust hash) invalid
      encoded <- except (Data.decodeCbor bytes)
      case inlineHash of
        Nothing -> pure ()
        Just expected -> do
          actual <- ExceptT (Data.hash encoded)
          unless (Blake2b.toBytes actual == Datum.hashBytes expected) invalid
      pure (Datum.InlineDatum encoded)
    Nothing -> do
      when (inlinePresent || isJust inlineHash) invalid
      pure (maybe Datum.NoDatum Datum.DatumHash hash)
  result <- except (Output.mkOutput address amount dat script)
  pure (Utxo.utxo reference result)
  where
    parser = withObject "Hydra output" $ \o -> do
      reference <- case Text.splitOn "#" (Key.toText key) of
        [tx, index] -> C.input "tx_hash" "index" (object ["tx_hash" .= tx, "index" .= index])
        _ -> fail "Invalid input reference"
      address <- o .: "address" >>= C.checked . Address.fromText
      amount <-
        o .: "value"
          >>= withObject
            "value"
            ( \v -> do
                coins <- maybe (pure 0) C.natural (KM.lookup "lovelace" v)
                assets <- concat <$> traverse asset [(p, a) | (p, a) <- KM.toList v, p /= "lovelace"]
                C.checked (C.unique (map fst assets))
                pure (Amount.lovelace (toInteger coins) <> foldMap (uncurry Amount.singleton) assets)
            )
      hash <- o .:? "datumhash" >>= traverse hashValue
      raw <- o .:? "inlineDatumRaw" >>= traverse Json.parseHex
      inlineHash <- o .:? "inlineDatumhash" >>= traverse hashValue
      inline <- o .:? "inlineDatum" :: Parser (Maybe Value)
      script <- o .:? "referenceScript" >>= traverse scriptValue
      pure (reference, address, amount, hash, raw, inlineHash, isJust inline, script)
    hashValue text = Json.parseHex text >>= C.checked . Datum.hashFromBytes
    asset (policy, value) = withObject "assets" (traverse (token (Key.toText policy)) . KM.toList) value
    token policy (name, value) = do
      identifier <- Json.parseAsset (policy <> Key.toText name)
      quantity <- C.natural value
      when (quantity == 0) (fail "Zero asset quantity")
      pure (identifier, toInteger quantity)
    scriptValue = withObject "reference script" $ \o -> do
      language <- o .: "scriptLanguage"
      o .: "script"
        >>= withObject
          "script envelope"
          ( \s -> do
              kind <- s .: "type"
              bytes <- s .: "cborHex" >>= Json.parseHex
              if kind == ("SimpleScript" :: Text)
                then do
                  unless (language == ("SimpleScriptLanguage" :: Text)) (fail "Script language mismatch")
                  Script.Native <$> C.checked (Native.decodeCbor bytes)
                else do
                  version <- maybe (fail "Unsupported Hydra script language") pure (lookup kind [("PlutusScriptV1", Plutus.V1), ("PlutusScriptV2", Plutus.V2), ("PlutusScriptV3", Plutus.V3)])
                  unless (language == "PlutusScriptLanguage " <> kind) (fail "Script language mismatch")
                  Script.Plutus <$> C.checked (Plutus.decodeCbor version bytes)
          )

findDatum :: Datum.Hash32 -> [Utxo.Utxo] -> ExceptT Error IO (Maybe Data.EncodedPlutusData)
findDatum _ [] = pure Nothing
findDatum expected (u : rest) = case Output.datum (Utxo.output u) of
  Datum.InlineDatum encoded -> do
    hash <- ExceptT (Data.hash encoded)
    if Blake2b.toBytes hash == Datum.hashBytes expected then pure (Just encoded) else findDatum expected rest
  _ -> findDatum expected rest

submit :: Http.Transport -> Tx.Transaction -> ExceptT Error IO TxId.TransactionId
submit transport transaction = do
  expected <- ExceptT (Tx.transactionId transaction)
  response <- request transport (jsonRequest Http.Post ["transaction"] [] (Just (object ["type" .= ("Tx ConwayEra" :: Text), "description" .= ("" :: Text), "cborHex" .= Hex.encodeHex (Tx.encodeCbor transaction)])))
  value <- except (Json.decodeValue "hydra.submitTransaction" (Http.bodyBytes response))
  tag <- parse (withObject "submission" (.: "tag")) value
  case (Http.status response, tag :: Text) of
    (200, "SubmitTxConfirmed") -> parse (C.field "snapshotNumber" >=> C.natural) value >> pure expected
    (202, "SubmitTxSubmitted") -> pure expected
    (status, _) | status /= 200 && status /= 202 -> throwE (ProviderHttpError "hydra.submitTransaction" status)
    _ -> invalid

-- Poll only explicit confirmed transaction records. A committed L1 output is
-- not evidence that its originating transaction was executed inside the Head.
confirmed :: Http.Transport -> TxId.TransactionId -> Int -> ExceptT Error IO Bool
confirmed transport expected remaining = do
  result <- json transport ((jsonRequest Http.Get ["snapshot"] [] Nothing) {Http.requestTimeoutMillis = Just remaining}) True
  case result of
    Nothing -> pure False
    Just value -> do
      tag <- parse (withObject "snapshot" (.: "tag")) value
      case tag :: Text of
        "InitialSnapshot" -> pure False
        "ConfirmedSnapshot" -> do
          snapshot <- parse (C.field "snapshot") value
          _ <- parse (C.field "number" >=> C.natural) snapshot
          rows <- parse (C.field "confirmed" >=> C.list) snapshot
          identifiers <- traverse identifier rows
          pure (expected `elem` identifiers)
        _ -> invalid
  where
    identifier row = do
      (encoded, claimed) <- parse (withObject "transaction" (\o -> (,) <$> (o .: "cborHex" >>= Json.parseHex >>= C.checked . Tx.decodeCbor) <*> o .:? "txId")) row
      actual <- ExceptT (Tx.transactionId encoded)
      unless (maybe True (== TxId.toHex actual) claimed) invalid
      pure actual

await :: Config.Config -> Http.Transport -> TxId.TransactionId -> Word64 -> ExceptT Error IO Bool
await _ _ _ 0 = pure False
await config transport identifier milliseconds = ExceptT $ do
  start <- toInteger <$> getMonotonicTimeNSec
  loop (start + toInteger milliseconds * 1000000)
  where
    loop deadline = do
      now <- toInteger <$> getMonotonicTimeNSec
      if now >= deadline
        then pure (Right False)
        else do
          let remaining = fromInteger (min (toInteger (Config.responseTimeoutMillis config)) ((deadline - now + 999999) `div` 1000000))
          result <- runExceptT (confirmed transport identifier remaining)
          finished <- toInteger <$> getMonotonicTimeNSec
          case result of
            Left failure | finished >= deadline && failure == transportError Http.Timeout -> pure (Right False)
            Left failure -> pure (Left failure)
            Right True -> pure (Right (finished <= deadline))
            Right False -> do
              let delay = min (toInteger (Config.pollIntervalMillis config) * 1000) (max 0 ((deadline - finished) `div` 1000))
              when (delay > 0) (threadDelay (fromInteger delay))
              loop deadline
