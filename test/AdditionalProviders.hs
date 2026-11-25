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

-- | Identical public API fixtures across bindings, with explicit failure cases.
module AdditionalProviders (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.Protocol.ExUnits as Units
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import qualified Cometa.Provider.Hydra as PublicHydra
import qualified Cometa.Provider.Internal.Codec as C
import qualified Cometa.Provider.Internal.Hydra as Hydra
import qualified Cometa.Provider.Internal.Remote as Remote
import qualified Cometa.Provider.Koios as Koios
import qualified Cometa.Provider.Kupmios as Kupmios
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TxId
import Control.Concurrent (threadDelay)
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (withText)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

must :: (Show e) => Either e a -> IO a
must = either (\e -> assertFailure (show e) >> fail "fixture") pure

fixture :: FilePath -> IO Value
fixture name = B.readFile ("test/fixtures/providers/" <> name <> ".json") >>= must . eitherDecodeStrict'

field :: Text -> Value -> IO Value
field key = must . C.parse (C.field key)

reply :: Int -> Value -> Http.Response
reply status value = Http.Response status (Lazy.toStrict (encode value)) Nothing

rpc :: Value -> Value
rpc value = object ["jsonrpc" .= ("2.0" :: Text), "id" .= ("cometa" :: Text), "result" .= value]

sampleTx :: IO Tx.Transaction
sampleTx = maybe (fail "hex fixture") (must . Tx.decodeCbor) (Hex.decodeHex "84a3008001800200a0f5f6")

scripted :: Text -> [Http.Response] -> (Provider.Provider -> IO ()) -> IO ()
scripted backend responses action = do
  pending <- newIORef responses
  let config = (Config.defaultConfig Config.Preprod Nothing) {Config.pollIntervalMillis = 1}
      send _ = do
        result <-
          atomicModifyIORef'
            pending
            ( \case
                [] -> ([], Nothing)
                y : ys -> (ys, Just y)
            )
        maybe (assertFailure "Unexpected request" >> pure (Left Http.ConnectionFailure)) (pure . Right) result
      transport = Http.Transport send (pure (Right ()))
      provider = case backend of
        "Koios" -> Remote.provider Remote.Koios config transport transport
        "Kupmios" -> Remote.provider Remote.Kupmios config transport transport
        _ -> Hydra.provider config transport
  action provider
  remaining <- readIORef pending
  unless (null remaining) (assertFailure "Unused expected requests")

tests :: TestTree
tests =
  testGroup
    "Additional providers"
    [ testGroup
        "shared contracts"
        [ testGroup
            (show backend)
            [ testCase "complete protocol snapshot" (parameters backend),
              testCase "HTTP errors propagate" (httpErrors backend),
              testCase "zero timeout makes no request" (zeroTimeout backend),
              testCase "submission validates response" (submission backend),
              testCase "unexpected budgets fail" (evaluation backend),
              testCase "complete, missing and duplicate budgets" (evaluationCoverage backend)
            ]
        | backend <- ["Koios", "Kupmios", "Hydra"]
        ],
      testCase "Koios live UTxOs retain reference scripts" koiosOutputs,
      testCase "Koios rejects duplicate and spent results" koiosDuplicates,
      testCase "Hydra upstream outputs preserve native and Plutus scripts" hydraOutputs,
      testCase "Hydra rejects missing inline datum bytes" hydraMissingDatum,
      testCase "Hydra snapshot records establish L2 confirmation" hydraConfirmation,
      testCase "Hydra deposits are not treated as L2 confirmations" hydraDeposit,
      testCase "public scopes reject escaped providers" scopes,
      testCase "credentials reject header injection without printable secrets" credentials
    ]

parameters :: Text -> Assertion
parameters backend = do
  source <- fixture (if backend == "Hydra" then "hydra-parameters" else "ogmios-parameters")
  response <- if backend == "Hydra" then pure source else rpc <$> field "result" source
  scripted backend [reply 200 response] $ \provider -> do
    result <- Provider.protocolParameters provider >>= must
    P.parameterAdaPerUtxoByte result @?= Just 4310
    P.parameterProtocolVersion result @?= Version.ProtocolVersion 11 0
    P.parameterMinFeeA result @?= if backend == "Hydra" then 0 else 44
    fmap P.referenceScriptCostStride (P.parameterRefScriptCostStride result) @?= Just 25600
    assertBool "governance retained" (isJust (P.parameterDrepVotingThresholds result))

httpErrors :: Text -> Assertion
httpErrors backend = forM_ [401, 403, 429, 500] $ \status ->
  scripted backend [reply status (String "credential-secret")] $ \p -> do
    result <- Provider.protocolParameters p
    case result of
      Left (ProviderHttpError _ actual) -> actual @?= status
      _ -> assertFailure "HTTP status was swallowed"

zeroTimeout :: Text -> Assertion
zeroTimeout backend = do
  tx <- sampleTx >>= Tx.transactionId >>= must
  scripted backend [] $ \p -> Provider.awaitTransaction p tx 0 >>= (@?= Right False)

submission :: Text -> Assertion
submission backend = do
  transaction <- sampleTx
  actual <- Tx.transactionId transaction >>= must
  if backend == "Hydra"
    then do
      scripted backend [reply 202 (object ["tag" .= ("SubmitTxSubmitted" :: Text)])] $ \p -> Provider.submitTransaction p transaction >>= (@?= Right actual)
      scripted backend [reply 200 (object ["tag" .= ("SubmitTxSubmitted" :: Text)])] $ \p -> Provider.submitTransaction p transaction >>= rejected
    else do
      wrong <- must (TxId.fromBytes (B.replicate 32 1))
      scripted backend [reply 200 (rpc (object ["transaction" .= object ["id" .= TxId.toHex wrong]]))] $ \p -> Provider.submitTransaction p transaction >>= rejected

evaluation :: Text -> Assertion
evaluation backend = do
  transaction <- sampleTx
  let result = rpc (toJSON [object ["validator" .= object ["purpose" .= ("spend" :: Text), "index" .= (0 :: Int)], "budget" .= object ["memory" .= (1 :: Int), "cpu" .= (2 :: Int)]]])
  scripted backend [reply 200 result | backend /= "Hydra"] $ \p -> Provider.evaluateTransaction p transaction [] >>= rejected

koiosOutputs :: Assertion
koiosOutputs = do
  source <- fixture "koios-utxos"
  rows <- must (C.parse C.list source)
  case rows of
    [] -> assertFailure "missing fixture outputs"
    first : _ -> do
      text <- field "address" first >>= must . C.parse (withText "address" pure)
      address <- must (Address.fromText text)
      scripted "Koios" [reply 200 source] $ \p -> do
        result <- Provider.utxosAt p address >>= must
        length result @?= length rows
        length [() | u <- result, isJust (Output.referenceScript (Utxo.output u))] @?= 3

koiosDuplicates :: Assertion
koiosDuplicates = do
  source <- fixture "koios-utxos"
  rows <- must (C.parse C.list source)
  case rows of
    [] -> assertFailure "missing fixture"
    first : _ -> do
      address <- field "address" first >>= must . C.parse (withText "address" (C.checked . Address.fromText))
      scripted "Koios" [reply 200 (toJSON [first, first])] $ \p -> Provider.utxosAt p address >>= rejected
      let spent = case first of
            Object o -> Object (KM.insert "is_spent" (Bool True) o)
            _ -> first
      scripted "Koios" [reply 200 (toJSON [spent])] $ \p -> Provider.utxosAt p address >>= (@?= Right [])

hydraOutputs :: Assertion
hydraOutputs = do
  source <- fixture "hydra-utxos"
  case source of
    Object rows -> forM_ (KM.toList rows) $ \(_, row) -> do
      address <- field "address" row >>= must . C.parse (withText "address" (C.checked . Address.fromText))
      scripted "Hydra" [reply 200 source] $ \p -> do
        outputs <- Provider.utxosAt p address >>= must
        length outputs @?= 1
        forM_ outputs $ \u -> assertBool "reference script retained" (isJust (Output.referenceScript (Utxo.output u)))
    _ -> assertFailure "invalid fixture"

hydraConfirmation :: Assertion
hydraConfirmation = do
  tx <- sampleTx
  hash <- Tx.transactionId tx >>= must
  let response = object ["tag" .= ("ConfirmedSnapshot" :: Text), "snapshot" .= object ["number" .= (1 :: Int), "confirmed" .= [object ["cborHex" .= Hex.encodeHex (Tx.encodeCbor tx), "txId" .= TxId.toHex hash]]]]
  scripted "Hydra" [reply 200 response] $ \p -> Provider.awaitTransaction p hash 1000 >>= (@?= Right True)

hydraDeposit :: Assertion
hydraDeposit = do
  tx <- sampleTx >>= Tx.transactionId >>= must
  let response = object ["tag" .= ("InitialSnapshot" :: Text), "initialUTxO" .= object [Key.fromText (TxId.toHex tx <> "#0") .= object []]]
  -- A single poll occupies the entire short deadline without a second request.
  pending <- newIORef (0 :: Int)
  let transport = Http.Transport (\_ -> atomicModifyIORef' pending (\x -> (x + 1, ())) >> threadDelay 2000 >> pure (Right (reply 200 response))) (pure (Right ()))
      p = Hydra.provider (Config.defaultConfig Config.Preprod Nothing) transport
  Provider.awaitTransaction p tx 1 >>= (@?= Right False)

scopes :: Assertion
scopes = do
  a <- Koios.withProvider (Koios.defaultConfig Koios.Preprod Nothing) (pure . Right) >>= must
  b <- Kupmios.withProvider (Kupmios.defaultConfig Kupmios.Preprod "http://localhost:1" "http://localhost:2") (pure . Right) >>= must
  c <- PublicHydra.withProvider (PublicHydra.defaultConfig PublicHydra.Preprod "http://localhost:1") (pure . Right) >>= must
  forM_ [a, b, c] $ \p -> Provider.resolveInputs p [] >>= (@?= Left RuntimeClosed)

credentials :: Assertion
credentials = do
  case Koios.mkApiKey "valid.jwt-token_123" of
    Left _ -> assertFailure "valid credential rejected"
    Right _ -> pure ()
  case Koios.mkApiKey "key\r\nOther: value" of
    Left _ -> pure ()
    Right _ -> assertFailure "header injection accepted"

rejected :: Either e a -> Assertion
rejected (Left _) = pure ()
rejected (Right _) = assertFailure "Expected rejection"

evaluationCoverage :: Text -> Assertion
evaluationCoverage "Hydra" = pure ()
evaluationCoverage backend = do
  transaction <- maybe (fail "fixture hex") (must . Tx.decodeCbor) (Hex.decodeHex "84a3008001800200a1058184000000820000f5f6")
  let budget = object ["validator" .= object ["purpose" .= ("spend" :: Text), "index" .= (0 :: Int)], "budget" .= object ["memory" .= (17 :: Int), "cpu" .= (29 :: Int)]]
  scripted backend [reply 200 (rpc (toJSON [budget]))] $ \p -> do
    result <- Provider.evaluateTransaction p transaction [] >>= must
    map snd (Evaluation.budgets result) @?= [Units.ExUnits 17 29]
  forM_ [[], [budget, budget]] $ \values ->
    scripted backend [reply 200 (rpc (toJSON values))] $ \p -> Provider.evaluateTransaction p transaction [] >>= rejected

hydraMissingDatum :: Assertion
hydraMissingDatum = do
  source <- fixture "hydra-utxos"
  case source of
    Object rows -> forM_ (KM.toList rows) $ \(key, row) -> case row of
      Object fields -> do
        address <- field "address" row >>= must . C.parse (withText "address" (C.checked . Address.fromText))
        let malformed = Object (KM.insert "inlineDatumRaw" Null (KM.insert "inlineDatumhash" (String "1111111111111111111111111111111111111111111111111111111111111111") fields))
        scripted "Hydra" [reply 200 (Object (KM.singleton key malformed))] $ \provider -> Provider.utxosAt provider address >>= rejected
      _ -> assertFailure "invalid output fixture"
    _ -> assertFailure "invalid fixture"
