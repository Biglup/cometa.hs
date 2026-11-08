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

-- | Encoding controls over the existing native body corpus and typed witnesses.
module SetEncoding (tests) where

import Cometa.Encoding.Set (SetEncoding (..))
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad (forM_, when)
import Data.Either (isLeft)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import qualified TransactionBody as Bodies
import qualified TransactionWitnesses as WitnessCorpus

tests :: TestTree
tests =
  testGroup
    "Set encoding controls"
    [ testCase "body corpus supports per-field tags without semantic changes" checkBodies,
      testCase "subbody corpus supports only its own set fields" checkSubBodies,
      testCase "every witness collection retains exact values and native tags" checkWitnesses,
      testCase "nonminimal tags and indefinite payloads preserve exact bytes" checkExact,
      testCase "encoding-only body edits invalidate signatures at both levels" checkSignatures,
      testCase "fresh encoders choose tags explicitly" checkFresh
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "Invalid fixture") pure

checkBodies :: IO ()
checkBodies = forM_ Bodies.bodyVectors $ \(_, hex) -> do
  original <- Bodies.bytes hex >>= must . Body.decodeCbor
  forM_ [minBound .. maxBound] $ \field -> forM_ [TaggedSet, UntaggedSet] $ \requested -> do
    let changed = Body.withSetEncoding field requested original
    Body.toBody changed @?= Body.toBody original
    Body.decodeCbor (Body.toCbor changed) @?= Right changed
    Body.withSetEncoding field requested changed @?= changed
    case Body.setEncoding field original of
      Nothing -> changed @?= original
      Just previous -> do
        Body.setEncoding field changed @?= Just requested
        when (previous == requested) (changed @?= original)

checkSubBodies :: IO ()
checkSubBodies = forM_ Bodies.subBodyVectors $ \(_, hex) -> do
  original <- Bodies.bytes hex >>= must . SubBody.decodeCbor
  forM_ [minBound .. maxBound] $ \field -> forM_ [TaggedSet, UntaggedSet] $ \requested -> do
    let changed = SubBody.withSetEncoding field requested original
    SubBody.toBody changed @?= SubBody.toBody original
    SubBody.decodeCbor (SubBody.toCbor changed) @?= Right changed
    SubBody.withSetEncoding field requested changed @?= changed
    case SubBody.setEncoding field original of
      Nothing -> changed @?= original
      Just previous -> do
        SubBody.setEncoding field changed @?= Just requested
        when (previous == requested) (changed @?= original)

checkWitnesses :: IO ()
checkWitnesses = do
  (_, _, _, values, _) <- must (WitnessCorpus.sample 7 42)
  let original = Witnesses.fromWitnesses values
  forM_ [minBound .. maxBound] $ \field -> forM_ [TaggedSet, UntaggedSet] $ \requested -> do
    let changed = Witnesses.withSetEncoding field requested original
        semantic = Witnesses.toWitnesses changed
    Witnesses.setEncoding field changed @?= Just requested
    Witnesses.decodeCbor (Witnesses.toCbor changed) @?= Right changed
    Witnesses.verificationWitnesses semantic @?= Witnesses.verificationWitnesses values
    Witnesses.bootstrapWitnesses semantic @?= Witnesses.bootstrapWitnesses values
    Witnesses.scripts semantic @?= Witnesses.scripts values
    Witnesses.datums semantic @?= Witnesses.datums values
    Witnesses.redeemers semantic @?= Witnesses.redeemers values
    Witnesses.withSetEncoding field requested changed @?= changed
    WitnessCorpus.agree 3 (Witnesses.toCbor changed)
  let absent = Witnesses.fromWitnesses Witnesses.empty
  Witnesses.withSetEncoding Witnesses.Datums TaggedSet absent @?= absent

checkExact :: IO ()
checkExact = do
  forM_ ["d90102", "da00000102", "db0000000000000102"] $ \tag -> do
    raw <- Bodies.bytes ("bf00" ++ tag ++ "9fff0180021800ff")
    original <- must (Body.decodeCbor raw)
    Body.setEncoding Body.Inputs original @?= Just TaggedSet
    Body.withSetEncoding Body.Inputs TaggedSet original @?= original
    let untagged = Body.withSetEncoding Body.Inputs UntaggedSet original
    expected <- Bodies.bytes "a3009fff0180021800"
    Body.toCbor untagged @?= expected
    Body.toBody untagged @?= Body.toBody original
    witnessRaw <- Bodies.bytes ("bf04" ++ tag ++ "9f1801ffff")
    witness <- must (Witnesses.decodeCbor witnessRaw)
    Witnesses.withSetEncoding Witnesses.Datums TaggedSet witness @?= witness
    witnessExpected <- Bodies.bytes "a1049f1801ff"
    Witnesses.toCbor (Witnesses.withSetEncoding Witnesses.Datums UntaggedSet witness) @?= witnessExpected
  forM_ ["a300d901038001800200", "a300d90102d901028001800200"] $ \hex -> do
    raw <- Bodies.bytes hex
    assertBool "invalid outer set tag" (isLeft (Body.decodeCbor raw))

checkSignatures :: IO ()
checkSignatures = do
  (_, _, _, values, _) <- must (WitnessCorpus.sample 7 42)
  original <- must (Body.fromBody (Body.body [] [] 0))
  let witness = Witnesses.fromWitnesses values
      transaction = Tx.assemble original witness Nothing
      changed = Tx.setBodySetEncoding Body.Inputs UntaggedSet transaction
      remaining = Witnesses.toWitnesses (Tx.witnesses changed)
  Tx.setBodySetEncoding Body.Inputs TaggedSet transaction @?= transaction
  Tx.setBodySetEncoding Body.Proposals UntaggedSet transaction @?= transaction
  Body.setEncoding Body.Inputs (Tx.body changed) @?= Just UntaggedSet
  Witnesses.verificationWitnesses remaining @?= []
  Witnesses.bootstrapWitnesses remaining @?= []
  Witnesses.scripts remaining @?= Witnesses.scripts values
  Witnesses.datums remaining @?= Witnesses.datums values
  Witnesses.redeemers remaining @?= Witnesses.redeemers values
  before <- Tx.transactionId transaction >>= must
  after <- Tx.transactionId changed >>= must
  assertBool "body encoding changes transaction id" (before /= after)
  subBody <- must (SubBody.fromBody (SubBody.body [] []))
  let intent = Sub.assemble subBody witness Nothing
      edited = Sub.setBodySetEncoding SubBody.Inputs UntaggedSet intent
  Sub.setBodySetEncoding SubBody.Inputs TaggedSet intent @?= intent
  SubBody.setEncoding SubBody.Inputs (Sub.body edited) @?= Just UntaggedSet
  Witnesses.verificationWitnesses (Witnesses.toWitnesses (Sub.witnesses edited)) @?= []
  Witnesses.bootstrapWitnesses (Witnesses.toWitnesses (Sub.witnesses edited)) @?= []
  Witnesses.scripts (Witnesses.toWitnesses (Sub.witnesses edited)) @?= Witnesses.scripts values

checkFresh :: IO ()
checkFresh = do
  forM_ [TaggedSet, UntaggedSet] $ \requested -> do
    bytes <- must (Body.encodeCborWith requested (Body.body [] [] 7))
    encoded <- must (Body.decodeCbor bytes)
    Body.setEncoding Body.Inputs encoded @?= Just requested
    Bodies.nativeResult 0 bytes >>= (@?= if requested == TaggedSet then 0 else 9001)
    subBytes <- must (SubBody.encodeCborWith requested (SubBody.body [] []))
    subEncoded <- must (SubBody.decodeCbor subBytes)
    SubBody.setEncoding SubBody.Inputs subEncoded @?= Just requested
    Bodies.nativeResult 1 subBytes >>= (@?= if requested == TaggedSet then 0 else 9001)
    (_, _, _, witnesses, _) <- must (WitnessCorpus.sample 7 42)
    let witnessBytes = Witnesses.encodeCborWith requested witnesses
    witnessEncoded <- must (Witnesses.decodeCbor witnessBytes)
    forM_ [minBound .. maxBound] $ \field -> Witnesses.setEncoding field witnessEncoded @?= Just requested
    WitnessCorpus.agree 3 witnessBytes
