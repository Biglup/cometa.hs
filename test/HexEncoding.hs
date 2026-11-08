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

module HexEncoding (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Credential as Credential
import qualified Cometa.Encoding.Hex as Hex
import Cometa.Error (Error (InvalidHex))
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as Data
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Data.ByteString as B
import Data.Either (isLeft)
import qualified Data.Text as Text
import Hedgehog (Property, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Raw hexadecimal encoding"
    [ testCase "all byte values have independent lowercase encodings" vectors,
      testCase "empty and mixed-case raw inputs are accepted" accepted,
      testCase "malformed syntax fails without partial bytes" rejected,
      testCase "raw bytes compose with existing domain validators" typedWorkflows,
      testProperty "arbitrary byte snapshots round trip in either case" roundTrip
    ]

must :: (Show error) => Either error value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

vectors :: IO ()
vectors = do
  let bytes = B.pack [0 .. 255]
      hexadecimal =
        "000102030405060708090a0b0c0d0e0f"
          <> "101112131415161718191a1b1c1d1e1f"
          <> "202122232425262728292a2b2c2d2e2f"
          <> "303132333435363738393a3b3c3d3e3f"
          <> "404142434445464748494a4b4c4d4e4f"
          <> "505152535455565758595a5b5c5d5e5f"
          <> "606162636465666768696a6b6c6d6e6f"
          <> "707172737475767778797a7b7c7d7e7f"
          <> "808182838485868788898a8b8c8d8e8f"
          <> "909192939495969798999a9b9c9d9e9f"
          <> "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
          <> "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
          <> "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
          <> "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
          <> "e0e1e2e3e4e5e6e7e8e9eaebecedeeef"
          <> "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
  Hex.encode bytes @?= hexadecimal
  Hex.decode hexadecimal @?= Right bytes
  Hex.decode (Text.toUpper hexadecimal) @?= Right bytes

accepted :: IO ()
accepted = do
  Hex.encode B.empty @?= ""
  Hex.decode "" @?= Right B.empty
  Hex.decode "aBcDeF" @?= Right (B.pack [0xab, 0xcd, 0xef])
  Hex.encode (B.pack [0, 0, 128, 255]) @?= "000080ff"
  Hex.decode "000080ff" @?= Right (B.pack [0, 0, 128, 255])

rejected :: IO ()
rejected =
  mapM_
    (\text -> Hex.decode text @?= Left InvalidHex)
    [ "0",
      "000",
      "0x00",
      "0X00",
      "00 ",
      " 00",
      "00\n",
      "00\t",
      "0g",
      "gg",
      "+0",
      "-0",
      "０0",
      "٠0",
      "é0",
      "00\NUL00",
      "0000gg",
      "\r\n"
    ]

typedWorkflows :: IO ()
typedWorkflows = do
  -- The public module's example uses the script's existing byte validator.
  script <- must (Hex.decode "0102" >>= Plutus.fromBytes Plutus.V3)
  Plutus.toBytes script @?= B.pack [1, 2]
  assertBool "Empty raw bytes bypassed Plutus validation" (isLeft (Hex.decode "" >>= Plutus.fromBytes Plutus.V3))
  condition <- must (Hex.decode "820401" >>= Native.decodeCbor)
  Native.encodeCbor condition @?= B.pack [0x82, 4, 1]
  credential <- must (Hex.decode (Text.replicate 28 "aB") >>= Credential.scriptHashFromBytes)
  Credential.scriptHashBytes credential @?= B.replicate 28 0xab
  assertBool "Short raw hash bypassed credential validation" (isLeft (Hex.decode "00" >>= Credential.scriptHashFromBytes))
  metadatum <- must (Hex.decode "00ff" >>= Metadata.mkBytes)
  Metadata.encodeMetadatumCbor metadatum @?= B.pack [0x42, 0, 255]
  encodedData <- must (Hex.decode "1801" >>= Data.decodeCbor)
  Data.toCbor encodedData @?= B.pack [0x18, 1]
  Data.toData encodedData @?= Data.Integer 1
  assertBool "Malformed CBOR bypassed script-data validation" (isLeft (Hex.decode "ff" >>= Data.decodeCbor))

roundTrip :: Property
roundTrip = property $ do
  bytes <- forAll (Gen.bytes (Range.linear 0 1024))
  let text = Hex.encode bytes
  Hex.decode text === Right bytes
  Hex.decode (Text.toUpper text) === Right bytes
  Text.length text === 2 * B.length bytes
