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

-- | Complete pinned transaction JSON fixtures and fresh-owner failure paths.
module TransactionInspection (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.Internal.Inspection as Internal
import qualified Cometa.PlutusData as Data
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Inspection as Inspection
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO)
import Control.Monad (forM, forM_, replicateM, replicateM_, (>=>))
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import qualified Fixtures.Inspection as Fixture
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Transaction JSON inspection"
    [ testCase "complete pinned Conway/Dijkstra and native rich JSON matches" corpus,
      testCase "inspection leaves exact bytes, transaction IDs and signatures unchanged" identities,
      testCase "arbitrary integers and binary data retain their JSON meaning" largeValues,
      testCase "malformed, truncated and trailing CBOR fail on every native entrypoint" failures,
      testCase "repeated calls and returned JSON outlive cleanup and collection" repeated,
      testCase "independent concurrent inspections return complete snapshots" concurrent
    ]

must :: (Show error) => Either error value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

load :: Fixture.Fixture -> IO (Tx.Transaction, Value)
load fixture = do
  bytes <- maybe (assertFailure "Invalid fixture hexadecimal" >> fail "fixture") pure (Hex.decodeHex (Fixture.fixtureCbor fixture))
  transaction <- must (Tx.decodeCbor bytes)
  expected <- must (eitherDecodeStrict' (Fixture.fixtureJson fixture))
  pure (transaction, expected)

field :: Key -> Value -> IO Value
field key (Object values) = maybe (assertFailure "Missing expected JSON field" >> fail "fixture") pure (KeyMap.lookup key values)
field _ _ = assertFailure "Expected JSON object" >> fail "fixture"

corpus :: IO ()
corpus = forM_ Fixture.fixtures $ \fixture -> do
  (transaction, expected) <- load fixture
  Inspection.transaction transaction >>= (@?= Right expected)
  expectedBody <- field "body" expected
  Inspection.body (Tx.body transaction) >>= (@?= Right expectedBody)
  let subs = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
  expectedSubs <- case expectedBody of
    Object values -> case KeyMap.lookup "sub_transactions" values of
      Nothing -> pure []
      Just (Array values') -> pure (toList values')
      _ -> assertFailure "Invalid expected subtransaction array" >> fail "fixture"
    _ -> assertFailure "Invalid expected body" >> fail "fixture"
  length subs @?= length expectedSubs
  forM_ (zip subs expectedSubs) $ \(sub, json) -> do
    Inspection.subTransaction sub >>= (@?= Right json)
    expectedSubBody <- field "body" json
    Inspection.subBody (Sub.body sub) >>= (@?= Right expectedSubBody)
    case json of
      Object values -> do
        assertBool "subtransaction acquired a validity flag" (not (KeyMap.member "is_valid" values))
        case expectedSubBody of
          Object fields -> assertBool "subtransaction acquired a fee" (not (KeyMap.member "fee" fields))
          _ -> assertFailure "Invalid expected subtransaction body"
      _ -> assertFailure "Invalid expected subtransaction"

identities :: IO ()
identities = forM_ Fixture.fixtures $ \fixture -> do
  (transaction, _) <- load fixture
  let original = Tx.encodeCbor transaction
      witnessBytes = Witnesses.toCbor (Tx.witnesses transaction)
      subs = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
      subBytes = map Sub.encodeCbor subs
  originalId <- Tx.transactionId transaction
  _ <- Inspection.transaction transaction >>= must
  mapM_ (Inspection.subTransaction >=> must) subs
  Tx.encodeCbor transaction @?= original
  Witnesses.toCbor (Tx.witnesses transaction) @?= witnessBytes
  Tx.transactionId transaction >>= (@?= originalId)
  map Sub.encodeCbor subs @?= subBytes

largeValues :: IO ()
largeValues = do
  let huge = 2 ^ (160 :: Int) + 3
      datum = Data.fromData (Data.List [Data.Integer huge, Data.Integer (negate huge), Data.Bytes (B.pack [0, 255, 128, 0])])
      expectedDatum =
        object
          [ "tag" .= ("list" :: Text.Text),
            "contents"
              .= [ object ["tag" .= ("integer" :: Text.Text), "value" .= Text.pack (show huge)],
                   object ["tag" .= ("integer" :: Text.Text), "value" .= Text.pack (show (negate huge))],
                   object ["tag" .= ("bytes" :: Text.Text), "value" .= ("00ff8000" :: Text.Text)]
                 ]
          ]
  body <- must (Body.fromBody (Body.body [] [] maxBound))
  witnesses <- must (Witnesses.mkWitnesses [] [] [] [datum] [])
  let transaction = Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing
      expected = object ["body" .= object ["inputs" .= ([] :: [Value]), "outputs" .= ([] :: [Value]), "fee" .= ("18446744073709551615" :: Text.Text)], "is_valid" .= True, "witness_set" .= object ["plutus_data" .= [expectedDatum]]]
  Inspection.transaction transaction >>= (@?= Right expected)

failures :: IO ()
failures = do
  let invalid = [B.empty, B.singleton 0xff, B.singleton 0xa1, B.singleton 0xf6]
  replicateM_ 25 $ forM_ [0 .. 3] $ \kind -> forM_ invalid (Internal.runUnchecked kind >=> (assertBool "Malformed CBOR inspection succeeded" . isLeft))
  forM_ Fixture.fixtures $ \fixture -> do
    (transaction, _) <- load fixture
    Internal.runUnchecked 0 (Tx.encodeCbor transaction <> B.singleton 0) >>= assertBool "Trailing transaction bytes accepted" . isLeft
    Internal.runUnchecked 2 (Body.toCbor (Tx.body transaction) <> B.singleton 0) >>= assertBool "Trailing body bytes accepted" . isLeft
    forM_ (fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))) $ \sub -> do
      Internal.runUnchecked 1 (Sub.encodeCbor sub <> B.singleton 0) >>= assertBool "Trailing subtransaction bytes accepted" . isLeft
      Internal.runUnchecked 3 (SubBody.toCbor (Sub.body sub) <> B.singleton 0) >>= assertBool "Trailing sub-body bytes accepted" . isLeft
  Internal.runUnchecked 4 B.empty >>= assertBool "Unknown native inspection operation succeeded" . isLeft
  assertBool "Invalid CBOR constructed a public transaction" (isLeft (Tx.decodeCbor (B.singleton 0xff)))

repeated :: IO ()
repeated = forM_ Fixture.fixtures $ \fixture -> do
  (transaction, expected) <- load fixture
  values <- replicateM 20 (Inspection.transaction transaction >>= must)
  performGC
  map encode values @?= replicate 20 (encode expected)

concurrent :: IO ()
concurrent = do
  fixtures <- traverse load Fixture.fixtures
  completions <- forM fixtures $ \(transaction, expected) -> do
    finished <- newEmptyMVar
    _ <- forkFinally (Inspection.transaction transaction >>= (@?= Right expected)) (putMVar finished)
    pure finished
  forM_ completions $ \finished -> do
    outcome <- takeMVar finished
    either (throwIO :: SomeException -> IO ()) pure outcome
