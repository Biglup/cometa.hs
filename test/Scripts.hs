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
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Typed script construction, exact identity, native conformance and VM goldens.
module Scripts (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.PlutusData as Data
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar, throwTo)
import Control.Exception (AsyncException (ThreadKilled), fromException)
import Control.Monad (forM_, forever, replicateM_)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import qualified Fixtures.Scripts as Fixtures
import Foreign.C.Types (CChar, CInt (..), CSize (..))
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Scripts"
    [ testCase "native script construction JSON validates every alternative" checkJson,
      testCase "all native alternatives assemble to pinned bytes and agree with native hash" checkNative,
      testCase "threshold and slot extrema retain full unsigned range" checkBounds,
      testCase "native imported encodings and child identity remain exact" checkIdentity,
      testCase "native parser rejects malformed alternatives, credentials and trailing input" checkInvalidNative,
      testCase "all Plutus versions have independent hash vectors and native agreement" checkPlutus,
      testCase "Plutus outer encodings are exact while hashes use compiled bytes" checkPlutusIdentity,
      testCase "combined envelopes normalize without changing payload identity" checkEnvelope,
      testCase "combined and Plutus parsers reject invalid framing" checkInvalidEnvelope,
      testCase "typed VM parameter application matches pinned golden corpus" checkApply,
      testCase "VM errors, result snapshots and original values survive repeated cleanup" checkLifetime,
      testCase "cancellation unwinds VM calls and leaves independent operations usable" checkCancellation,
      testProperty "assembled native scripts round trip without loss" propNative
    ]

nativeValues :: IO [Native.NativeScript]
nativeValues = do
  keyBytes <- bytes "00112233445566778899aabbccddeeff00112233445566778899aabb"
  scriptBytes <- bytes "aabbccddeeff00112233445566778899aabbccddeeff001122334455"
  key <- expectRight (Credential.keyHashFromBytes keyBytes)
  guardKey <- expectRight (Credential.keyHashFromBytes keyBytes)
  guardHash <- expectRight (Credential.scriptHashFromBytes scriptBytes)
  let signed = Native.signature key
      guarded = Native.requireGuard (Credential.KeyCredential guardKey)
      scriptGuard = Native.requireGuard (Credential.ScriptCredential guardHash)
  pure
    [ signed,
      Native.allOf [],
      Native.anyOf [],
      Native.atLeast 0 [],
      Native.invalidBefore 0,
      Native.invalidAfter maxBound,
      guarded,
      scriptGuard,
      Native.allOf [signed, guarded],
      Native.anyOf [scriptGuard],
      Native.atLeast 1 [guarded]
    ]

checkNative :: IO ()
checkNative = do
  values <- nativeValues
  forM_ (zip values Fixtures.nativeVectors) $ \(script, golden) -> do
    expected <- bytes golden
    Native.encodeCbor script @?= expected
    decoded <- expectRight (Native.decodeCbor expected)
    decoded @?= script
    Native.view decoded @?= Native.view script
    nativeAgreement (Script.Native script)
  digest <- Native.hash (Native.allOf []) >>= expectRight
  expected <- bytes "d441227553a0f1a965fee7d60a0f724b368dd1bddbc208730fccebcf"
  Credential.scriptHashBytes digest @?= expected

checkBounds :: IO ()
checkBounds = do
  forM_ [0, 1, maxBound :: Word64] $ \count -> do
    let script = Native.atLeast count []
    Native.view script @?= Native.RequireAtLeast count []
    Native.decodeCbor (Native.encodeCbor script) @?= Right script
    nativeAgreement (Script.Native script)
  forM_ [0, 1, maxBound :: Word64] $ \slot -> forM_ [Native.invalidBefore slot, Native.invalidAfter slot] $ \script -> do
    Native.decodeCbor (Native.encodeCbor script) @?= Right script
    nativeAgreement (Script.Native script)

checkIdentity :: IO ()
checkIdentity = do
  encoded <- bytes "9f18041801ff"
  script <- expectRight (Native.decodeCbor encoded)
  Native.view script @?= Native.InvalidBefore 1
  Native.encodeCbor script @?= encoded
  digest <- Native.hash script >>= expectRight
  expectedDigest <- bytes "39ba2bf155ed91d0af8648e127e7def677e9b9f2dcad79c987c83b53"
  Credential.scriptHashBytes digest @?= expectedDigest
  assertBool "representation-sensitive equality" (script /= Native.invalidBefore 1)
  Native.encodeCbor (Native.allOf [script]) @?= ByteString.pack [0x82, 1, 0x81] <> encoded
  reparsed <- expectRight (Native.decodeCbor (Native.encodeCbor (Native.allOf [script])))
  Native.view reparsed @?= Native.RequireAll [script]

checkInvalidNative :: IO ()
checkInvalidNative = forM_ ["", "80", "8100", "83040000", "820700", "820020", "8200581b000000000000000000000000000000000000000000000000000000", "82061b00", "8206820200", "8206820040", "83032080", "82041b", "82040000", "9f040001ff"] $ \hex -> do
  encoded <- bytes hex
  assertBool ("reject native " <> hex) (isLeft (Native.decodeCbor encoded))

checkPlutus :: IO ()
checkPlutus = forM_ (zip [Plutus.V1 .. Plutus.V4] hashes) $ \(language, golden) -> do
  script <- expectRight (Plutus.fromBytes language Fixtures.compiledScript)
  Plutus.version script @?= language
  Plutus.toBytes script @?= Fixtures.compiledScript
  Plutus.encodeCbor script @?= ByteString.cons 0x46 Fixtures.compiledScript
  Plutus.decodeCbor language (Plutus.encodeCbor script) @?= Right script
  digest <- Plutus.hash script >>= expectRight
  expected <- bytes golden
  Credential.scriptHashBytes digest @?= expected
  nativeAgreement (Script.Plutus script)
  where
    hashes =
      [ "83497f63170b2119e6100fcd767a28894a250f577ba0418b1d43f084",
        "b003687053ba29e4e9667d34839714a53138140fe7b929363bd2bb2f",
        "7fb5e4100a4521d55108c5a193f25691547cbdfe676deae925042ae1",
        "1fd0190f1816f66a28208ce5836f64f54d99bdc2a088fee8e14547ed"
      ]

checkPlutusIdentity :: IO ()
checkPlutusIdentity = do
  canonical <- expectRight (Plutus.fromBytes Plutus.V3 Fixtures.compiledScript)
  forM_
    [ ByteString.pack [0x58, 6] <> Fixtures.compiledScript,
      ByteString.pack [0x5f, 0x42, 0x45, 1, 0x44, 0, 0, 0x24, 0x99, 0xff]
    ]
    $ \encoded -> do
      script <- expectRight (Plutus.decodeCbor Plutus.V3 encoded)
      Plutus.encodeCbor script @?= encoded
      Plutus.toBytes script @?= Fixtures.compiledScript
      assertBool "outer representation participates in equality" (script /= canonical)
      left <- Plutus.hash script
      right <- Plutus.hash canonical
      left @?= right
  Plutus.fromBytes Plutus.V1 ByteString.empty @?= Left EmptyPlutusScript
  opaque <- expectRight (Plutus.fromBytes Plutus.V1 (ByteString.singleton 255))
  Plutus.toBytes opaque @?= ByteString.singleton 255

checkEnvelope :: IO ()
checkEnvelope = do
  original <- bytes "9f18009f18041801ffff"
  script <- expectRight (Script.decodeCbor original)
  normalized <- bytes "82009f18041801ff"
  Script.encodeCbor script @?= normalized
  Script.decodeCbor normalized @?= Right script
  forM_ [Plutus.V1 .. Plutus.V4] $ \language -> do
    plutus <- expectRight (Plutus.fromBytes language Fixtures.compiledScript)
    let combined = Script.Plutus plutus
    Script.decodeCbor (Script.encodeCbor combined) @?= Right combined
    combinedHash <- Script.hash combined
    plutusHash <- Plutus.hash plutus
    combinedHash @?= plutusHash

checkInvalidEnvelope :: IO ()
checkInvalidEnvelope = do
  forM_ ["", "80", "8100", "830082018000", "8205820180", "820100", "820082018000", "9f0082018000ff"] $ \hex -> do
    encoded <- bytes hex
    assertBool ("reject envelope " <> hex) (isLeft (Script.decodeCbor encoded))
  forM_ ["", "80", "41", "410000", "5f0100ff"] $ \hex -> do
    encoded <- bytes hex
    assertBool ("reject Plutus " <> hex) (isLeft (Plutus.decodeCbor Plutus.V1 encoded))
  empty <- bytes "40"
  Plutus.decodeCbor Plutus.V1 empty @?= Left EmptyPlutusScript

checkApply :: IO ()
checkApply = do
  let parameters = [[], [Data.Integer 0], [Data.Integer (2 ^ (64 :: Int))], [Data.Integer 0, Data.Bytes (ByteString.singleton 255)]]
  forM_ [Plutus.V1 .. Plutus.V4] $ \language -> do
    original <- expectRight (Plutus.fromBytes language Fixtures.compiledScript)
    forM_ (zip parameters Fixtures.applyVectors) $ \(params, (encodedParams, expectedCode)) -> do
      expectedParams <- bytes encodedParams
      Data.encodeCbor (Data.List params) @?= expectedParams
      expected <- bytes expectedCode
      applied <- Plutus.applyParams original params >>= expectRight
      Plutus.toBytes applied @?= expected
      Plutus.version applied @?= language
      Plutus.toBytes original @?= Fixtures.compiledScript
      nativeAgreement (Script.Plutus applied)
    first <- Plutus.applyParams original [Data.Integer 0] >>= expectRight
    sequential <- Plutus.applyParams first [Data.Bytes (ByteString.singleton 255)] >>= expectRight
    simultaneous <- Plutus.applyParams original [Data.Integer 0, Data.Bytes (ByteString.singleton 255)] >>= expectRight
    sequential @?= simultaneous

checkLifetime :: IO ()
checkLifetime = do
  original <- expectRight (Plutus.fromBytes Plutus.V2 Fixtures.compiledScript)
  result <- Plutus.applyParams original [Data.Integer 0] >>= expectRight
  invalid <- expectRight (Plutus.fromBytes Plutus.V2 (ByteString.singleton 255))
  replicateM_ 32 $ do
    failure <- Plutus.applyParams invalid [Data.Map [(Data.Integer 1, Data.Bytes ByteString.empty)]]
    assertBool "malformed Flat returns a native error" (case failure of Left NativeError {} -> True; _ -> False)
    _ <- Plutus.applyParams original [Data.Constr 0 [Data.Integer (-1)]] >>= expectRight
    performGC
  expected <- bytes "4b0100003249930101000001"
  Plutus.toBytes result @?= expected
  Plutus.toBytes original @?= Fixtures.compiledScript
  nativeAgreement (Script.Plutus result)

checkCancellation :: IO ()
checkCancellation = do
  original <- expectRight (Plutus.fromBytes Plutus.V3 Fixtures.compiledScript)
  invalid <- expectRight (Plutus.fromBytes Plutus.V3 (ByteString.singleton 255))
  forM_ [False, True] $ \malformed -> do
    started <- newEmptyMVar
    done <- newEmptyMVar
    let invoke = if malformed then Plutus.applyParams invalid [] else Plutus.applyParams original [Data.Bytes (ByteString.replicate 1024 7)]
    worker <-
      forkFinally
        ( do
            _ <- invoke
            putMVar started ()
            forever invoke
        )
        (putMVar done)
    began <- timeout 5000000 (takeMVar started)
    began @?= Just ()
    throwTo worker ThreadKilled
    stopped <- timeout 5000000 (takeMVar done)
    case stopped of
      Just (Left exception) -> fromException exception @?= Just ThreadKilled
      _ -> assertFailure "VM worker failed to unwind cancellation"
    after <- Plutus.applyParams original [] >>= expectRight
    Plutus.toBytes after @?= Fixtures.compiledScript
    nativeAgreement (Script.Plutus after)

propNative :: Property
propNative = property $ do
  slots <- forAll (Gen.list (Range.linear 0 20) (Gen.word64 Range.constantBounded))
  required <- forAll (Gen.word64 Range.constantBounded)
  let script = Native.allOf [Native.anyOf (map Native.invalidBefore slots), Native.atLeast required (map Native.invalidAfter slots)]
  decoded <- evalEither (Native.decodeCbor (Native.encodeCbor script))
  decoded === script
  Native.view decoded === Native.view script
  evalIO (nativeAgreement (Script.Native script))

nativeAgreement :: Script.Script -> IO ()
nativeAgreement script = do
  digest <- Script.hash script >>= expectRight
  let encoded = Script.encodeCbor script
  ByteString.useAsCStringLen encoded $ \(input, inputSize) ->
    ByteString.useAsCString (Credential.scriptHashBytes digest) $ \hashBytes -> do
      agrees <- cAgreement (castPtr input) (fromIntegral inputSize) (castPtr hashBytes) (castPtr input) (fromIntegral inputSize)
      agrees @?= 1

bytes :: String -> IO ByteString.ByteString
bytes encoded = case Hex.decodeHex (Text.pack encoded) of
  Nothing -> assertFailure "invalid test fixture hex" >> pure ByteString.empty
  Just value -> pure value

expectRight :: (Show failure) => Either failure value -> IO value
expectRight result = case result of
  Left failure -> assertFailure (show failure) >> fail "unreachable assertion"
  Right value -> pure value

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_script_agreement"
  cAgreement :: Ptr Word8 -> CSize -> Ptr Word8 -> Ptr Word8 -> CSize -> IO CInt

checkJson :: IO ()
checkJson = do
  key <- expectRight (Credential.keyHashFromBytes (ByteString.replicate 28 7))
  guardKey <- expectRight (Credential.keyHashFromBytes (ByteString.replicate 28 8))
  guardScript <- expectRight (Credential.scriptHashFromBytes (ByteString.replicate 28 9))
  let sig = Native.signature key
      scripts = [sig, Native.allOf [], Native.anyOf [sig, sig], Native.atLeast maxBound [sig], Native.invalidBefore maxBound, Native.invalidAfter 0, Native.requireGuard (Credential.KeyCredential guardKey), Native.requireGuard (Credential.ScriptCredential guardScript)]
  forM_ (Native.allOf scripts : scripts) $ \script -> do
    let json = Native.toJson script
    Native.fromJson json @?= Right script
    ByteString.useAsCStringLen (Lazy.toStrict (Aeson.encode json)) $ \(jsonPtr, jsonSize) ->
      ByteString.useAsCStringLen (Native.encodeCbor script) $ \(expected, expectedSize) -> do
        agrees <- cScriptJson jsonPtr (fromIntegral jsonSize) (castPtr expected) (fromIntegral expectedSize)
        agrees @?= 1
  forM_ ["{}", "[]", "{\"type\":\"unknown\"}", "{\"type\":\"before\",\"slot\":-1}", "{\"type\":\"after\",\"slot\":18446744073709551616}", "{\"type\":\"atLeast\",\"required\":1.5,\"scripts\":[]}", "{\"type\":\"guard\",\"keyHash\":\"00\",\"scriptHash\":\"00\"}", "{\"type\":\"sig\",\"keyHash\":\"zz\"}", "{\"type\":\"all\",\"scripts\":[{}]}"] $ \encoded -> do
    json <- expectRight (Aeson.eitherDecodeStrict encoded)
    assertBool "invalid script construction JSON" (isLeft (Native.fromJson json))

foreign import ccall safe "cometa_test_native_script_json"
  cScriptJson :: Ptr CChar -> CSize -> Ptr Word8 -> CSize -> IO CInt
