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

-- | Body fixtures originate in cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/transaction_body/*.cpp, Apache-2.0. Source filenames and constant
-- names are retained below. Tests rebuild fresh public semantic values before
-- separate native getter/constructor reconstruction, never a source body cache.
module TransactionBody (tests, bodyVectors, subBodyVectors, bytes, agree, nativeResult) where

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int64)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Transaction bodies"
    [ testCase "pinned complete ordinary and Dijkstra body schemas reconstruct" checkBodies,
      testCase "pinned maximal Dijkstra subbody reconstructs all fields" checkSubBodies,
      testCase "legacy, inline datum, reference script and bounded pointer outputs reconstruct" checkOutputs,
      testCase "uint64 input references and exact bytes" checkInputs,
      testCase "exact nonminimal body hash and controlled fee edit" checkIdentity,
      testCase "datum identity inside nested guard and inline output slices" checkNestedIdentity,
      testCase "output quantity, hash, mint and association boundaries" checkBoundaries,
      testCase "malformed and unknown body fields fail without dropping data" checkMalformed,
      testCase "resolved UTxO snapshot uses typed input and output" checkUtxo,
      testCase "asset names, mixed-network associations and input sets use native ordering" checkOrdering,
      testProperty "fee edits are independent and fresh native bodies agree" propFee,
      testProperty "typed output quantities reconstruct across native int64 range" propOutput
    ]

must :: (Show e) => Either e a -> IO a
must value = case value of
  Left err -> assertFailure (show err) >> fail "Fixture validation failed"
  Right result -> pure result

bytes :: String -> IO ByteString
bytes text = maybe (assertFailure "Invalid fixture hex" >> fail "Invalid fixture hex") pure (Hex.decodeHex (Text.pack text))

agree :: CUInt -> ByteString -> IO ()
agree kind payload = nativeResult kind payload >>= (@?= 0)

-- | Native reconstruction status; 9001 means successful reconstruction with a
-- different encoding, such as native input sets emitting tag 258.
nativeResult :: CUInt -> ByteString -> IO CInt
nativeResult kind payload = B.useAsCStringLen payload $ \(ptr, size) ->
  cAgreement kind (castPtr ptr) (fromIntegral size)

checkBodies :: IO ()
checkBodies = forM_ bodyVectors $ \(name, hex) -> do
  payload <- bytes hex
  encoded <- must (Body.decodeCbor payload)
  Body.toCbor encoded @?= payload
  let semantic = Body.toBody encoded
  -- Empty historical guards remain exact imports but fresh assembly rejects
  -- them instead of silently deleting field presence.
  if "EMPTY" `Text.isInfixOf` Text.pack name
    then assertBool name (isLeft (Body.encodeCbor semantic))
    else do
      fresh <- must (Body.encodeCbor semantic)
      decoded <- must (Body.decodeCbor fresh)
      assertBool name (Body.toBody decoded == semantic)
      agree 0 fresh

checkSubBodies :: IO ()
checkSubBodies = forM_ subBodyVectors $ \(name, hex) -> do
  payload <- bytes hex
  encoded <- must (SubBody.decodeCbor payload)
  SubBody.toCbor encoded @?= payload
  case name of
    "sub_transaction_body.cpp/MINIMAL_CBOR" -> do
      digest <- SubBody.hash encoded >>= must
      Id.toHex digest @?= "da4603f4488d798af667794ab542f130a4bd1c20c7ed950c4648aaa95d0be4f4"
    "sub_transaction_body.cpp/MAXIMAL_CBOR" -> do
      digest <- SubBody.hash encoded >>= must
      Id.toHex digest @?= "29f569946d1ad32690effd3c74cfe3d437fae9bdf2797b6afa5d6d46e291da9e"
    _ -> pure ()
  fresh <- must (SubBody.encodeCbor (SubBody.toBody encoded))
  decoded <- must (SubBody.decodeCbor fresh)
  SubBody.toBody decoded @?= SubBody.toBody encoded
  agree 1 fresh

checkOutputs :: IO ()
checkOutputs = do
  forM_ outputVectors $ \(_, hex) -> do
    payload <- bytes hex
    encoded <- must (Output.decodeCbor payload)
    Output.toCbor encoded @?= payload
    let fresh = Output.encodeCbor (Output.toOutput encoded)
    decoded <- must (Output.decodeCbor fresh)
    Output.toOutput decoded @?= Output.toOutput encoded
    agree 2 fresh
  -- The pinned native pointer fixture has slot 16,292,793,057. Native address
  -- reconstruction truncates pointer fields to uint32; reject this overflow
  -- explicitly instead of presenting a lossy semantic snapshot.
  overflow <- bytes "825826412813b99a80cfb4024374bd0f502959485aa56e0648564ff805f2e51bbcd9819561bddc66141a02faf080"
  assertBool "pinned pointer slot overflow rejected" (isLeft (Output.decodeCbor overflow))
  key <- must (Credential.keyHashFromBytes (B.replicate 28 9))
  let pointer = Shelley.pointer Network.mainnet (Credential.KeyCredential key) (Shelley.StakePointer maxBound maxBound maxBound)
  bounded <- must (Output.mkOutput (Address.ShelleyAddress pointer) (Value.lovelace 1) Datum.NoDatum Nothing)
  agree 2 (Output.encodeCbor bounded)

checkInputs :: IO ()
checkInputs = do
  txId <- must (Id.fromBytes (B.replicate 32 11))
  forM_ [0, 1, maxBound] $ \ix -> do
    let reference = Input.input txId ix
    Input.decodeCbor (Input.encodeCbor reference) @?= Right reference
    Input.index reference @?= ix
    agree 3 (Input.encodeCbor reference)

checkIdentity :: IO ()
checkIdentity = do
  payload <- bytes "bf18009fff18019fff18021800ff"
  encoded <- must (Body.decodeCbor payload)
  Body.toCbor encoded @?= payload
  digest <- Body.hash encoded >>= must
  -- Independent BLAKE2b-256 vector generated with Python hashlib, recorded here.
  Id.toHex digest @?= "60b9f97f0685ea6efefa4cf9c7fbae7ff953ae4ea907fa65804f8131c25c873a"
  let original = Body.toBody encoded
      edited = Body.setFee maxBound original
  Body.bodyFields edited @?= Body.bodyFields original
  Body.fee original @?= 0
  Body.fee edited @?= maxBound
  fresh <- must (Body.encodeCbor original)
  assertBool "fresh semantic reassembly changes nonminimal identity" (fresh /= payload)
  Body.toCbor (Body.setFeeEncoded 0 encoded) @?= payload
  changed <- must (Body.decodeCbor (Body.toCbor (Body.setFeeEncoded maxBound encoded)))
  Body.fee (Body.toBody changed) @?= maxBound

checkNestedIdentity :: IO ()
checkNestedIdentity = do
  -- Nonminimal constructor/integer encoding must survive two nested wrappers.
  inline <- must (Data.decodeCbor (B.pack [0x18, 0x01]))
  destination <- destinationAddress
  out <- must (Output.mkOutput destination (Value.lovelace 2) (Datum.InlineDatum inline) Nothing)
  fresh <- must (Body.encodeCbor (Body.body [] [out] 0))
  encoded <- must (Body.decodeCbor fresh)
  case Fields.fieldOutputs (Body.bodyFields (Body.toBody encoded)) of
    [value] -> case Output.datum value of
      Datum.InlineDatum dat -> Data.toCbor dat @?= B.pack [0x18, 0x01]
      _ -> assertFailure "Lost inline datum alternative"
    _ -> assertFailure "Lost output"
  guard <- Credential.ScriptCredential <$> must (Credential.scriptHashFromBytes (B.replicate 28 7))
  required <- must (Fields.mkEntries [(guard, Just inline)])
  let minimal = Body.body [] [] 0
      body = minimal {Body.bodyFields = (Body.bodyFields minimal) {Fields.fieldRequiredTopLevelGuards = Just required}}
  bodyBytes <- must (Body.encodeCbor body)
  reloaded <- must (Body.decodeCbor bodyBytes)
  Fields.fieldRequiredTopLevelGuards (Body.bodyFields (Body.toBody reloaded)) @?= Just required

checkBoundaries :: IO ()
checkBoundaries = do
  destination <- destinationAddress
  assertBool "negative output" (isLeft (Output.mkOutput destination (Value.lovelace (-1)) Datum.NoDatum Nothing))
  assertBool "native int64 output overflow" (isLeft (Output.mkOutput destination (Value.lovelace (2 ^ (63 :: Int))) Datum.NoDatum Nothing))
  _ <- must (Output.mkOutput destination (Value.lovelace (toInteger (maxBound :: Int64))) Datum.NoDatum Nothing)
  forM_ [0, 31, 33] $ \size -> assertBool "digest size" (isLeft (Datum.hashFromBytes (B.replicate size 0)))
  let minimal = Body.body [] [] 0
  assertBool "present empty nested set rejected" (isLeft (Body.encodeCbor (minimal {Body.bodySubTransactions = Just []})))
  let duplicateGuard = Credential.KeyCredential <$> Credential.keyHashFromBytes (B.replicate 28 4)
  guard <- must duplicateGuard
  let invalidGuards = minimal {Body.bodyFields = (Body.bodyFields minimal) {Fields.fieldGuards = Just [guard, guard]}}
  assertBool "repeated fresh guards rejected" (isLeft (Body.fromBody invalidGuards))
  assertBool "mint Ada rejected" (isLeft (Fields.mkMint (Value.lovelace 1)))
  assertBool "empty association rejected" (isLeft (Fields.mkEntries ([] :: [(Word64, Word64)])))
  assertBool "equal duplicate association rejected" (isLeft (Fields.mkEntries [(1 :: Word64, 0 :: Word64), (1, 0)]))

checkMalformed :: IO ()
checkMalformed = do
  forM_ ["a0", "a200800180", "a40080018002000201", "a4008001800200181c00", "a3008001800220", "a300800180020000", "a40080018002001818a0"] $ \hex -> do
    payload <- bytes hex
    assertBool hex (isLeft (Body.decodeCbor payload))
  forM_ malformedSubVectors $ \(name, hex) -> do
    payload <- bytes hex
    assertBool name (isLeft (SubBody.decodeCbor payload))
  forM_ ["80", "a10040", "a3004001000101", "a300581d600000000000000000000000000000000000000000000000000000000001000400"] $ \hex -> do
    payload <- bytes hex
    assertBool hex (isLeft (Output.decodeCbor payload))

destinationAddress :: IO Address.Address
destinationAddress = do
  key <- must (Credential.keyHashFromBytes (B.replicate 28 3))
  pure (Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key)))

checkUtxo :: IO ()
checkUtxo = do
  destination <- destinationAddress
  txId <- must (Id.fromBytes (B.replicate 32 3))
  out <- must (Output.mkOutput destination (Value.lovelace 1) Datum.NoDatum Nothing)
  let snapshot = Utxo.utxo (Input.input txId maxBound) out
  Utxo.decodeCbor (Utxo.encodeCbor snapshot) @?= Right snapshot

checkOrdering :: IO ()
checkOrdering = do
  destination <- destinationAddress
  policy <- must (Policy.fromBytes (B.replicate 28 8))
  shortName <- must (AssetName.fromBytes (B.singleton 97))
  longName <- must (AssetName.fromBytes (B.pack [0, 0]))
  let bundle = Value.lovelace 1 <> Value.singleton (Asset.Native policy longName) 3 <> Value.singleton (Asset.Native policy shortName) 4
  output <- must (Output.mkOutput destination bundle Datum.NoDatum Nothing)
  agree 2 (Output.encodeCbor output)

  key <- must (Credential.keyHashFromBytes (B.replicate 28 1))
  script <- must (Credential.scriptHashFromBytes (B.replicate 28 2))
  let mainKey = Reward.fromCredential Network.mainnet (Credential.KeyCredential key)
      testScript = Reward.fromCredential Network.testnet (Credential.ScriptCredential script)
  deposits <- must (Fields.mkEntries [(testScript, maxBound), (mainKey, 0)])
  txId <- must (Id.fromBytes (B.replicate 32 3))
  let low = Input.input txId 0
      high = Input.input txId maxBound
      minimal = Body.body [high, low, high] [output] 0
      transaction = minimal {Body.bodyFields = (Body.bodyFields minimal) {Fields.fieldDirectDeposits = Just deposits}}
  encoded <- must (Body.fromBody transaction)
  Fields.fieldInputs (Body.bodyFields (Body.toBody encoded)) @?= [low, high, high]
  agree 0 (Body.toCbor encoded)

propFee :: Property
propFee = property $ do
  amount <- forAll (Gen.word64 Range.constantBounded)
  replacement <- forAll (Gen.word64 Range.constantBounded)
  let original = Body.body [] [] amount
      changed = Body.setFee replacement original
  Body.fee original === amount
  Body.bodyFields changed === Body.bodyFields original
  fresh <- evalEither (Body.encodeCbor changed)
  decoded <- evalEither (Body.decodeCbor fresh)
  Body.toBody decoded === changed
  evalIO (agree 0 fresh)

propOutput :: Property
propOutput = property $ do
  amount <- forAll (Gen.integral (Range.constant 0 (toInteger (maxBound :: Int64))))
  destination <- evalIO destinationAddress
  output <- evalEither (Output.mkOutput destination (Value.lovelace amount) Datum.NoDatum Nothing)
  encoded <- evalEither (Output.decodeCbor (Output.encodeCbor output))
  Output.toOutput encoded === output
  evalIO (agree 2 (Output.encodeCbor output))

bodyVectors :: [(String, String)]
bodyVectors =
  [ ("transaction_body.cpp/MINIMAL_DIJKSTRA_BODY", "a300d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a"),
    ("transaction_body.cpp/GUARDS_KEY_HASH_FORM_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0e81581c6199186adb51974690d7247d2646097d2c62763b16fb7ed3f9f55d39"),
    ("transaction_body.cpp/GUARDS_UNTAGGED_INPUTS_BODY", "a400818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0e81581c6199186adb51974690d7247d2646097d2c62763b16fb7ed3f9f55d39"),
    ("transaction_body.cpp/GUARDS_TAGGED_KEY_HASH_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0ed9010282581c6199186adb51974690d7247d2646097d2c62763b16fb7ed3f9f55d39581c966e394a544f242081e41d1965137b1bb412ac230d40ed5407821c37"),
    ("transaction_body.cpp/GUARDS_EMPTY_TAGGED_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0ed9010280"),
    ("transaction_body.cpp/GUARDS_EMPTY_BARE_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0e80"),
    ("transaction_body.cpp/GUARDS_CREDENTIAL_FORM_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0e828200581c6199186adb51974690d7247d2646097d2c62763b16fb7ed3f9f55d398201581c966e394a544f242081e41d1965137b1bb412ac230d40ed5407821c37"),
    ("transaction_body.cpp/GUARDS_CREDENTIAL_TAGGED_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0ed90102828200581c6199186adb51974690d7247d2646097d2c62763b16fb7ed3f9f55d398201581c966e394a544f242081e41d1965137b1bb412ac230d40ed5407821c37"),
    ("transaction_body.cpp/GUARDS_SCRIPT_ONLY_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a0e818201581c966e394a544f242081e41d1965137b1bb412ac230d40ed5407821c37"),
    ("transaction_body.cpp/SUB_TRANSACTIONS_TAGGED_BODY", "a400d9010281825820ee155ace9c40292074cb6aff8c9ccdd273c81648ff1149ef36bcea6ebb8a3e25000180020017d901028283a300d90102800180031864a0a101647465737483a200d90102800180a0f6"),
    ("transaction_body.cpp/SUB_TRANSACTIONS_BARE_BODY", "a400d9010281825820ee155ace9c40292074cb6aff8c9ccdd273c81648ff1149ef36bcea6ebb8a3e250001800200178283a300d90102800180031864a0a101647465737483a200d90102800180a0f6"),
    ("transaction_body.cpp/REQUIRED_TOP_LEVEL_GUARDS_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a1818a18200581c00112233445566778899aabbccddeeff00112233445566778899aabbf6"),
    ("transaction_body.cpp/DIRECT_DEPOSITS_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a1819a2581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d01903e8581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce725701907d0"),
    ("transaction_body.cpp/ACCOUNT_BALANCE_INTERVALS_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a181aa3581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d0821864191388581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce72570821901f4f6581df0aabbccddeeff00112233445566778899aabbccddeeff00112233445582f6192710"),
    ("transaction_body.cpp/STARTING_ACCOUNT_BALANCE_INTERVALS_BODY", "a400d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a181ba2581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce7257082f6192710581df0aabbccddeeff00112233445566778899aabbccddeeff001122334455182a"),
    ("transaction_body.cpp/BOTH_ACCOUNT_BALANCE_INTERVALS_BODY", "a500d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a181aa3581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d0821864191388581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce72570821901f4f6581df0aabbccddeeff00112233445566778899aabbccddeeff00112233445582f6192710181ba2581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce7257082f6192710581df0aabbccddeeff00112233445566778899aabbccddeeff001122334455182a"),
    ("transaction_body.cpp/ALL_TOP_LEVEL_KEYS_BODY", "b81900d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000180020a031903e804d90102828304581c26b17b78de4f035dc0bfce60d1d3c3a8085c38dcce5fb8767e518bed1901f48405581c0d94e174732ef9aae73f395ab44507bfa983d65023c11a951f0c32e4581ca646474b8f5431261506b6c273d307c7569a4eb6c96b42dd4a29520a582003170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c11131405a2581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d005581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce72570030758202ceb364d93225b4a0f004a0975a13eb50c3cc6348474b4fe9121f8dc72ca0cfa08186409a3581c2a286ad895d091f2b3d168a6091ad2627d30a72761a5bc36eef00740a14014581c659f2917fb63f12b33667463ee575eeac1845bbc736b9c0bbc40ba82a14454534c413831581c7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373a240182846504154415445181e0b58206199186adb51974690d7247d2646097d2c62763b16fb7ed3f9f55d38abc123de0dd90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5010e828200581c6199186adb51974690d7247d2646097d2c62763b16fb7ed3f9f55d398201581c966e394a544f242081e41d1965137b1bb412ac230d40ed5407821c370f0110a2005839009493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e32c728d3861e164cab28cb8f006448139c8f1740ffb8e7aa9e5232dc01820aa3581c2a286ad895d091f2b3d168a6091ad2627d30a72761a5bc36eef00740a14014581c659f2917fb63f12b33667463ee575eeac1845bbc736b9c0bbc40ba82a14454534c411832581c7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373a240182846504154415445181e11186412d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d50013a28202581c10000000000000000000000000000000000000000000000000000000a38258201000000000000000000000000000000000000000000000000000000000000000038200827668747470733a2f2f7777772e736f6d6575726c2e696f582000000000000000000000000000000000000000000000000000000000000000008258202000000000000000000000000000000000000000000000000000000000000000038200827668747470733a2f2f7777772e736f6d6575726c2e696f582000000000000000000000000000000000000000000000000000000000000000008258203000000000000000000000000000000000000000000000000000000000000000038200827668747470733a2f2f7777772e736f6d6575726c2e696f582000000000000000000000000000000000000000000000000000000000000000008203581c20000000000000000000000000000000000000000000000000000000a28258201000000000000000000000000000000000000000000000000000000000000000038200827668747470733a2f2f7777772e736f6d6575726c2e696f582000000000000000000000000000000000000000000000000000000000000000008258203000000000000000000000000000000000000000000000000000000000000000038200827668747470733a2f2f7777772e736f6d6575726c2e696f5820000000000000000000000000000000000000000000000000000000000000000014d9010281841a000f4240581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f830582582000000000000000000000000000000000000000000000000000000000000000000382827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000f6827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000151907d0161903e817d901028283a300d90102800180031864a0a101647465737483a200d90102800180a0f61818a18200581c00112233445566778899aabbccddeeff00112233445566778899aabbf61819a2581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d01903e8581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce725701907d0181aa3581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d0821864191388581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce72570821901f4f6581df0aabbccddeeff00112233445566778899aabbccddeeff00112233445582f6192710181ba2581de0404b5a4088ae9abcf486a7e7b8f82069e6fcfe1bf226f1851ce7257082f6192710581df0aabbccddeeff00112233445566778899aabbccddeeff001122334455182a")
  ]

subBodyVectors :: [(String, String)]
subBodyVectors =
  [ ("sub_transaction_body.cpp/MINIMAL_CBOR", "a200d90102800180"),
    ("sub_transaction_body.cpp/MAXIMAL_CBOR", "b300d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000181825839009493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e32c728d3861e164cab28cb8f006448139c8f1740ffb8e7aa9e5232dc820aa3581c2a286ad895d091f2b3d168a6091ad2627d30a72761a5bc36eef00740a14014581c659f2917fb63f12b33667463ee575eeac1845bbc736b9c0bbc40ba82a14454534c411832581c7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373a240182846504154415445181e031903e804d90102818304581c26b17b78de4f035dc0bfce60d1d3c3a8085c38dcce5fb8767e518bed1901f405a1581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f050758200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d508186409a3581c2a286ad895d091f2b3d168a6091ad2627d30a72761a5bc36eef00740a14014581c659f2917fb63f12b33667463ee575eeac1845bbc736b9c0bbc40ba82a14454534c413831581c7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373a240182846504154415445181e0b58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d50ed90102828200581c00112233445566778899aabbccddeeff00112233445566778899aabb8201581caabbccddeeff00112233445566778899aabbccddeeff0011223344550f0112d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d50013a18202581c00112233445566778899aabbccddeeff00112233445566778899aabba18258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5038201f614d9010281841a000f4240581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8106827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000151907d0161903e81818a28200581c00112233445566778899aabbccddeeff00112233445566778899aabbf68201581caabbccddeeff00112233445566778899aabbccddeeff001122334455d879801819a1581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f1a000f4240181aa1581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d0821864191388"),
    ("sub_transaction_body.cpp/MAXIMAL_FRESH_CBOR", "b300d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5000181a2005839009493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e32c728d3861e164cab28cb8f006448139c8f1740ffb8e7aa9e5232dc01820aa3581c2a286ad895d091f2b3d168a6091ad2627d30a72761a5bc36eef00740a14014581c659f2917fb63f12b33667463ee575eeac1845bbc736b9c0bbc40ba82a14454534c411832581c7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373a240182846504154415445181e031903e804d90102818304581c26b17b78de4f035dc0bfce60d1d3c3a8085c38dcce5fb8767e518bed1901f405a1581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f050758200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d508186409a3581c2a286ad895d091f2b3d168a6091ad2627d30a72761a5bc36eef00740a14014581c659f2917fb63f12b33667463ee575eeac1845bbc736b9c0bbc40ba82a14454534c413831581c7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373a240182846504154415445181e0b58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d50ed90102828200581c00112233445566778899aabbccddeeff00112233445566778899aabb8201581caabbccddeeff00112233445566778899aabbccddeeff0011223344550f0112d90102818258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d50013a18202581c00112233445566778899aabbccddeeff00112233445566778899aabba18258200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5038201f614d9010281841a000f4240581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8106827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000151907d0161903e81818a28200581c00112233445566778899aabbccddeeff00112233445566778899aabbf68201581caabbccddeeff00112233445566778899aabbccddeeff001122334455d879801819a1581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f1a000f4240181aa1581de013cf55d175ea848b87deb3e914febd7e028e2bf6534475d52fb9c3d0821864191388")
  ]

outputVectors :: [(String, String)]
outputVectors =
  [ ("transaction_output.cpp/CBOR", "a400583900537ba48a023f0a3c65e54977ffc2d78c143fb418ef6db058e006d78a7c16240714ea0e12b41a914f2945784ac494bb19573f0ca61a08afa801821a000f4240a2581c00000000000000000000000000000000000000000000000000000000a3443031323218644433343536186344404142420a581c11111111111111111111111111111111111111111111111111111111a3443031323218644433343536186344404142420a028201d81849d8799f0102030405ff03d8185182014e4d01000033222220051200120011"),
    ("transaction_output.cpp/LEGACY_OUTPUT_CBOR", "83583900537ba48a023f0a3c65e54977ffc2d78c143fb418ef6db058e006d78a7c16240714ea0e12b41a914f2945784ac494bb19573f0ca61a08afa8821a000f4240a2581c00000000000000000000000000000000000000000000000000000000a3443031323218644433343536186344404142420a581c11111111111111111111111111111111111111111111111111111111a3443031323218644433343536186344404142420a58200000000000000000000000000000000000000000000000000000000000000000"),
    ("transaction_output.cpp/LEGACY_OUTPUT_NO_DATUM_CBOR", "82583900537ba48a023f0a3c65e54977ffc2d78c143fb418ef6db058e006d78a7c16240714ea0e12b41a914f2945784ac494bb19573f0ca61a08afa8821a000f4240a2581c00000000000000000000000000000000000000000000000000000000a3443031323218644433343536186344404142420a581c11111111111111111111111111111111111111111111111111111111a3443031323218644433343536186344404142420a"),
    ("transaction_output.cpp/BABBAGE_INLINE_DATUM_CBOR", "a300583900537ba48a023f0a3c65e54977ffc2d78c143fb418ef6db058e006d78a7c16240714ea0e12b41a914f2945784ac494bb19573f0ca61a08afa801821a000f4240a2581c00000000000000000000000000000000000000000000000000000000a3443031323218644433343536186344404142420a581c11111111111111111111111111111111111111111111111111111111a3443031323218644433343536186344404142420a028201d81849d8799f0102030405ff"),
    ("transaction_output.cpp/BABBAGE_DATUM_HASH_CBOR", "a400583900537ba48a023f0a3c65e54977ffc2d78c143fb418ef6db058e006d78a7c16240714ea0e12b41a914f2945784ac494bb19573f0ca61a08afa801821a000f4240a2581c00000000000000000000000000000000000000000000000000000000a3443031323218644433343536186344404142420a581c11111111111111111111111111111111111111111111111111111111a3443031323218644433343536186344404142420a0282005820000000000000000000000000000000000000000000000000000000000000000003d8185182014e4d01000033222220051200120011"),
    ("transaction_output.cpp/BABBAGE_REF_SCRIPT_CBOR", "a300583900537ba48a023f0a3c65e54977ffc2d78c143fb418ef6db058e006d78a7c16240714ea0e12b41a914f2945784ac494bb19573f0ca61a08afa801821a000f4240a2581c00000000000000000000000000000000000000000000000000000000a3443031323218644433343536186344404142420a581c11111111111111111111111111111111111111111111111111111111a3443031323218644433343536186344404142420a03d8185182014e4d01000033222220051200120011"),
    ("transaction_output.cpp/BABBAGE_NO_OPTIONAL_FIELD_SCRIPT_CBOR", "82583900537ba48a023f0a3c65e54977ffc2d78c143fb418ef6db058e006d78a7c16240714ea0e12b41a914f2945784ac494bb19573f0ca61a08afa8821a000f4240a2581c00000000000000000000000000000000000000000000000000000000a3443031323218644433343536186344404142420a581c11111111111111111111111111111111111111111111111111111111a3443031323218644433343536186344404142420a")
  ]

malformedSubVectors :: [(String, String)]
malformedSubVectors =
  [ ("sub_transaction_body.cpp/FEE_KEY_CBOR", "a300d90102800180020a"),
    ("sub_transaction_body.cpp/COLLATERAL_KEY_CBOR", "a300d901028001800d00"),
    ("sub_transaction_body.cpp/COLLATERAL_RETURN_KEY_CBOR", "a300d901028001801000"),
    ("sub_transaction_body.cpp/TOTAL_COLLATERAL_KEY_CBOR", "a300d901028001801100"),
    ("sub_transaction_body.cpp/NESTED_SUB_TX_KEY_CBOR", "a300d901028001801700"),
    ("sub_transaction_body.cpp/STARTING_INTERVALS_KEY_CBOR", "a300d90102800180181ba0"),
    ("sub_transaction_body.cpp/UNKNOWN_KEY_CBOR", "a300d90102800180186300"),
    ("sub_transaction_body.cpp/MISSING_INPUTS_CBOR", "a10180"),
    ("sub_transaction_body.cpp/MISSING_OUTPUTS_CBOR", "a100d9010280"),
    ("sub_transaction_body.cpp/EMPTY_WITHDRAWALS_CBOR", "a300d9010280018005a0"),
    ("sub_transaction_body.cpp/EMPTY_REQUIRED_GUARDS_CBOR", "a300d901028001801818a0")
  ]

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_transaction_body_agree"
  cAgreement :: CUInt -> Ptr Word8 -> CSize -> IO CInt
