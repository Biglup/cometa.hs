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
-- The decoder argument must remain polymorphic for cborg input ownership.
{-# LANGUAGE RankNTypes #-}

-- | Native transaction collection contracts through existing public values.
-- Original tests; reviewed GHC ghc-9.6.7-release Data.OldList.deleteBy (BSD), and
-- cardano-c c5edc7c8f16b3980b6e97ef7fda80fef94adf980 common/utxo_list.c,
-- collections/array.c and transaction_body/transaction_output.c (Apache-2.0).
-- Bounds are checked explicitly; host list clamping is not claimed as native
-- bounds behavior. Native semantic equality is separate from encoded identity.
module TransactionCollectionOperations (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Read as R
import qualified Codec.CBOR.Write as W
import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad (forM_, replicateM, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.List (delete, deleteBy)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hedgehog (Property, classify, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- TYPES ----------------------------------------------------------------------

data ListReply = ListReply Bool [Utxo.Utxo] (Maybe [Utxo.Utxo]) deriving (Eq, Show)

data ScriptReply = ScriptReply (Maybe ByteString) ByteString (Maybe ByteString) deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Transaction collection operations"
    [ testCase "slice and erase reject native bounds rather than clamp" checkBounds,
      testCase "remove deletes first semantic match and retains survivor payloads" checkRemoveIdentity,
      testCase "native import normalizes Plutus envelopes while preserving program bytes" checkImportIdentity,
      testCase "script-reference replacement retains payloads and getters outlive parents" checkScriptReferences,
      testCase "malformed inputs unwind and subsequent scopes recover" checkFailures,
      testProperty "generated native slices preserve order, duplicates and source" propSlice,
      testProperty "generated native erasures return removed and retained segments" propErase,
      testProperty "generated native removal uses structural fields rather than reference alone" propRemove
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "Invalid fixture") pure

scripts :: Either Error [Script.Script]
scripts = do
  retained <- Native.decodeCbor (B.pack [159, 24, 4, 24, 1, 255])
  plutus <- traverse (\version -> Script.Plutus <$> Plutus.fromBytes version (B.pack [1, 2, 3])) [minBound .. maxBound]
  retainedPlutus <- Script.Plutus <$> Plutus.decodeCbor Plutus.V2 (B.pack [88, 3, 1, 2, 3])
  pure ([Script.Native (Native.invalidBefore 1), Script.Native retained] <> plutus <> [retainedPlutus])

fixture :: Either Error [Utxo.Utxo]
fixture = do
  key <- Credential.keyHashFromBytes (B.replicate 28 7)
  let address = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
      make seed amount dat script = do
        identifier <- Id.fromBytes (B.replicate 32 seed)
        output <- Output.mkOutput address (Value.lovelace amount) dat script
        pure (Utxo.utxo (Input.input identifier 0) output)
  retainedDatum <- Data.decodeCbor (B.pack [24, 1])
  scriptValues <- scripts
  plainZero <- make 0 0 Datum.NoDatum Nothing
  plainOne <- make 0 1 Datum.NoDatum Nothing
  canonicalDatum <- make 1 10 (Datum.InlineDatum (Data.fromData (Data.Integer 1))) Nothing
  nonminimalDatum <- make 1 10 (Datum.InlineDatum retainedDatum) Nothing
  withScripts <- traverse (make 2 20 Datum.NoDatum . Just) scriptValues
  pure ([plainZero, plainOne, canonicalDatum, nonminimalDatum] <> withScripts)

-- Native Plutus import stores program bytes and regenerates their outer CBOR
-- bytestring. Public Plutus import retains that envelope, so establish the
-- native-import baseline explicitly before testing collection operations.
importedScript :: Script.Script -> Either Error Script.Script
importedScript value@(Script.Native _) = Right value
importedScript (Script.Plutus value) = Script.Plutus <$> Plutus.fromBytes (Plutus.version value) (Plutus.toBytes value)

importedOutput :: Output.Output -> Either Error Output.Output
importedOutput value = do
  reference <- traverse importedScript (Output.referenceScript value)
  Output.mkOutput (Output.address value) (Output.value value) (Output.datum value) reference

importedUtxo :: Utxo.Utxo -> Either Error Utxo.Utxo
importedUtxo value = Utxo.utxo (Utxo.input value) <$> importedOutput (Utxo.output value)

encodeList :: [Utxo.Utxo] -> ByteString
encodeList values = W.toStrictByteString (E.encodeListLen (fromIntegral (length values)) <> foldMap (E.encodePreEncoded . Utxo.encodeCbor) values)

-- Host bounds validation deliberately precedes take/drop. Native slice rejects
-- empty ranges; native erase permits zero count only at an existing index.
expectedSlice :: Int64 -> Word64 -> [Utxo.Utxo] -> ListReply
expectedSlice start end values
  | start < 0 || toInteger end > toInteger (length values) || toInteger start >= toInteger end = ListReply False values Nothing
  | otherwise = ListReply True values (Just (take (fromIntegral end - fromIntegral start) (drop (fromIntegral start) values)))

expectedErase :: Int64 -> Word64 -> [Utxo.Utxo] -> ListReply
expectedErase start count values
  | position < 0 || position >= total || position + toInteger count > total = ListReply False values Nothing
  | otherwise =
      let (before, rest) = splitAt (fromInteger position) values
          (removed, after) = splitAt (fromIntegral count) rest
       in ListReply True (before <> after) (Just removed)
  where
    total = toInteger (length values)
    position = if start < 0 then total + toInteger start else toInteger start

-- Native equality inspects script/data meaning while public Eq includes their
-- imported encodings. Use public semantic views explicitly for deleteBy.
sameUtxo :: Utxo.Utxo -> Utxo.Utxo -> Bool
sameUtxo left right = Utxo.input left == Utxo.input right && sameOutput (Utxo.output left) (Utxo.output right)
  where
    sameOutput a b = Output.address a == Output.address b && Output.value a == Output.value b && sameDatum (Output.datum a) (Output.datum b) && sameScript (Output.referenceScript a) (Output.referenceScript b)
    sameDatum Datum.NoDatum Datum.NoDatum = True
    sameDatum (Datum.DatumHash a) (Datum.DatumHash b) = a == b
    sameDatum (Datum.InlineDatum a) (Datum.InlineDatum b) = Data.toData a == Data.toData b
    sameDatum _ _ = False
    sameScript Nothing Nothing = True
    sameScript (Just (Script.Native a)) (Just (Script.Native b)) = Native.toJson a == Native.toJson b
    sameScript (Just (Script.Plutus a)) (Just (Script.Plutus b)) = Plutus.version a == Plutus.version b && Plutus.toBytes a == Plutus.toBytes b
    sameScript _ _ = False

checkBounds :: IO ()
checkBounds = do
  allValues <- must fixture
  let values = take 4 allValues
      starts = [minBound, -5, -4, -1, 0, 1, 3, 4, 5, maxBound]
      ends = [0, 1, 3, 4, 5, maxBound]
  forM_ [[], values] $ \source -> forM_ starts $ \start -> forM_ ends $ \end -> do
    listOracle 0 start end source Nothing >>= must >>= (@?= expectedSlice start end source)
    listOracle 1 start end source Nothing >>= must >>= (@?= expectedErase start end source)

checkRemoveIdentity :: IO ()
checkRemoveIdentity = do
  values <- must fixture
  case drop 2 values of
    canonical : retained : _ -> do
      assertBool "encoded datum equality is observable" (canonical /= retained)
      let source = [canonical, retained, canonical]
          expected = deleteBy sameUtxo retained source
      assertBool "plain Eq deletion has a different first match" (delete retained source /= expected)
      actual <- listOracle 2 0 0 source (Just retained) >>= must
      actual @?= ListReply True expected Nothing
      map Utxo.encodeCbor source @?= map Utxo.encodeCbor [canonical, retained, canonical]
    _ -> assertFailure "missing datum fixtures"
  case drop 4 values of
    canonical : retained : _ -> do
      assertBool "encoded native-script equality is observable" (canonical /= retained)
      let source = [canonical, retained, retained]
      listOracle 2 0 0 source (Just retained) >>= must >>= (@?= ListReply True (deleteBy sameUtxo retained source) Nothing)
    _ -> assertFailure "missing script fixtures"
  case values of
    base : _ -> do
      let key = Data.Integer 1
          bytes = Data.Bytes (B.pack [0, 255])
          fields = [Data.Integer 3, Data.Integer 4]
          first = (key, Data.List [Data.Bytes B.empty, Data.Constr 2 fields])
          second = (key, bytes)
          entries = [first, second]
          canonical = Data.fromData (Data.Map entries)
          different =
            [ Data.Map (reverse entries),
              Data.Map [first],
              Data.Map [(key, Data.List [Data.Constr 2 fields, Data.Bytes B.empty]), second],
              Data.Map [(key, Data.List [Data.Bytes B.empty, Data.Constr 3 fields]), second],
              Data.Map [(key, Data.List [Data.Bytes B.empty, Data.Constr 2 (reverse fields)]), second]
            ]
          make payload = do
            let original = Utxo.output base
            output <- Output.mkOutput (Output.address original) (Output.value original) (Datum.InlineDatum payload) Nothing
            pure (Utxo.utxo (Utxo.input base) output)
      B.take 2 (Data.toCbor canonical) @?= B.pack [162, 1]
      retained <- must (Data.decodeCbor (B.pack [162, 24, 1] <> B.drop 2 (Data.toCbor canonical)))
      prefix <- must (traverse (make . Data.fromData) different)
      normal <- must (make canonical)
      target <- must (make retained)
      assertBool "ordered maps, duplicate counts, lists and constructor fields remain distinct" (not (any (sameUtxo target) prefix))
      let source = prefix <> [normal, target, normal]
      listOracle 2 0 0 source (Just target) >>= must >>= (@?= ListReply True (prefix <> [target, normal]) Nothing)
    [] -> assertFailure "missing compound datum fixture"

checkImportIdentity :: IO ()
checkImportIdentity = do
  values <- must fixture
  case reverse values of
    value : _ -> do
      baseline <- must (importedUtxo value)
      let original = Utxo.output value
          expected = Utxo.output baseline
          bytes = Output.encodeCbor original
          expectedScript = Script.encodeCbor <$> Output.referenceScript expected
      assertBool "fixture distinguishes native import from exact public encoding" (value /= baseline)
      scriptOracle 0 bytes Nothing >>= must >>= (@?= ScriptReply expectedScript (Output.encodeCbor expected) expectedScript)
      listOracle 1 0 0 [value] Nothing >>= must >>= (@?= ListReply True [baseline] (Just []))
      case (Output.referenceScript original, Output.referenceScript expected) of
        (Just (Script.Plutus before), Just (Script.Plutus after)) -> Plutus.toBytes after @?= Plutus.toBytes before
        _ -> assertFailure "missing Plutus identity fixture"
      Output.encodeCbor original @?= bytes
    [] -> assertFailure "missing import fixture"

checkScriptReferences :: IO ()
checkScriptReferences = do
  values <- must fixture
  choices <- (Nothing :) . map Just <$> must scripts
  forM_ values $ \value -> forM_ choices $ \replacement -> do
    baseline <- must (importedOutput (Utxo.output value))
    requested <- must (traverse importedScript replacement)
    let original = Utxo.output value
        oldBytes = Script.encodeCbor <$> Output.referenceScript baseline
        bytes = Output.encodeCbor original
        indefinite = B.singleton 191 <> B.drop 1 bytes <> B.singleton 255
    expected <- must (Output.mkOutput (Output.address original) (Output.value original) (Output.datum original) requested)
    -- Native import normalizes map framing and Plutus bytestring envelopes.
    -- Inline datum/native-script CBOR and compiled program bytes remain exact;
    -- the original imported Haskell envelope remains unchanged throughout.
    imported <- must (Output.decodeCbor indefinite)
    actual <- scriptOracle 1 (Output.toCbor imported) replacement >>= must
    actual @?= ScriptReply oldBytes (Output.encodeCbor expected) (Script.encodeCbor <$> requested)
    Output.toCbor imported @?= indefinite
    forM_ [0, 2] $ \operation -> do
      unchanged <- scriptOracle operation bytes Nothing >>= must
      unchanged @?= ScriptReply oldBytes (Output.encodeCbor baseline) oldBytes

checkFailures :: IO ()
checkFailures = do
  values <- must fixture
  forM_ [B.empty, B.singleton 160, B.pack [129, 128], B.pack [129, 130, 128]] $ \invalid ->
    replicateM_ 3 (listBytesOracle 0 0 0 invalid B.empty >>= assertBool "malformed list accepted" . isLeft)
  forM_ [B.empty, B.singleton 128, B.pack [129, 128], B.pack [129, 130, 128]] $ \invalid ->
    replicateM_ 3 (scriptOracle 1 invalid Nothing >>= assertBool "malformed output accepted" . isLeft)
  case drop 4 values of
    value : _ -> do
      let partial = B.singleton 130 <> Utxo.encodeCbor value <> B.singleton 128
      listBytesOracle 0 0 0 partial B.empty >>= assertBool "partial list accepted" . isLeft
      forM_ [B.singleton 128, B.pack [130, 5, 64], B.pack [130, 0, 128, 0]] $ \invalid ->
        invoke (cScript 1) (Output.encodeCbor (Utxo.output value)) invalid scriptReplyDecoder >>= assertBool "malformed replacement accepted" . isLeft
    [] -> assertFailure "missing script fixture"
  baseline <- must (traverse importedUtxo values)
  listOracle 1 0 0 values Nothing >>= must >>= (@?= expectedErase 0 0 baseline)

propSlice :: Property
propSlice = property $ do
  choices <- evalEither fixture
  values <- forAll (Gen.list (Range.linear 0 15) (Gen.element choices))
  start <- forAll (Gen.int64 (Range.linear (-2) 18))
  end <- forAll (Gen.word64 (Range.linear 0 18))
  classify "empty range" (toInteger start == toInteger end)
  classify "out of bounds" (toInteger end > toInteger (length values))
  baseline <- evalEither (traverse importedUtxo values)
  actual <- evalIO (listOracle 0 start end values Nothing) >>= evalEither
  actual === expectedSlice start end baseline

propErase :: Property
propErase = property $ do
  choices <- evalEither fixture
  values <- forAll (Gen.list (Range.linear 0 15) (Gen.element choices))
  start <- forAll (Gen.int64 (Range.linear (-18) 18))
  count <- forAll (Gen.word64 (Range.linear 0 18))
  classify "negative relative index" (start < 0)
  classify "zero deletion" (count == 0)
  baseline <- evalEither (traverse importedUtxo values)
  actual <- evalIO (listOracle 1 start count values Nothing) >>= evalEither
  actual === expectedErase start count baseline

propRemove :: Property
propRemove = property $ do
  choices <- evalEither fixture
  values <- forAll (Gen.list (Range.linear 0 15) (Gen.element choices))
  target <- forAll (Gen.element choices)
  classify "semantic duplicates" (length (filter (sameUtxo target) values) > 1)
  classify "absent item" (not (any (sameUtxo target) values))
  baseline <- evalEither (traverse importedUtxo values)
  actual <- evalIO (listOracle 2 0 0 values (Just target)) >>= evalEither
  actual === ListReply True (deleteBy sameUtxo target baseline) Nothing

listOracle :: Int -> Int64 -> Word64 -> [Utxo.Utxo] -> Maybe Utxo.Utxo -> IO (Either String ListReply)
listOracle operation start count source target = listBytesOracle operation start count (encodeList source) (maybe B.empty Utxo.encodeCbor target)

listBytesOracle :: Int -> Int64 -> Word64 -> ByteString -> ByteString -> IO (Either String ListReply)
listBytesOracle operation start count source target = invoke (cList (fromIntegral operation) start count) source target listReplyDecoder

scriptOracle :: Int -> ByteString -> Maybe Script.Script -> IO (Either String ScriptReply)
scriptOracle operation source replacement = invoke (cScript (fromIntegral operation)) source (maybe B.empty Script.encodeCbor replacement) scriptReplyDecoder

invoke :: (Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt) -> ByteString -> ByteString -> (forall s. D.Decoder s a) -> IO (Either String a)
invoke operation source target decoder = B.useAsCStringLen source $ \(a, aSize) -> B.useAsCStringLen target $ \(b, bSize) ->
  allocaBytes 65536 $ \output -> alloca $ \size -> do
    code <- operation (castPtr a) (fromIntegral aSize) (castPtr b) (fromIntegral bSize) output 65536 size
    if code /= 0
      then pure (Left ("native collection status " <> show code))
      else do
        count <- peek size
        bytes <- B.packCStringLen (castPtr output, fromIntegral count)
        pure $ case R.deserialiseFromBytes decoder (L.fromStrict bytes) of
          Left failure -> Left (show failure)
          Right (rest, value) | L.null rest -> Right value
          Right _ -> Left "Trailing native reply"

listReplyDecoder :: D.Decoder s ListReply
listReplyDecoder = do
  count <- D.decodeListLen
  if count /= 3 then fail "Expected list reply" else ListReply <$> D.decodeBool <*> entries <*> optional entries
  where
    entries = D.decodeListLen >>= \size -> replicateM size (D.decodeBytes >>= either (fail . show) pure . Utxo.decodeCbor)

optional :: D.Decoder s a -> D.Decoder s (Maybe a)
optional decoder = do
  token <- D.peekTokenType
  if token == D.TypeNull then D.decodeNull >> pure Nothing else Just <$> decoder

scriptReplyDecoder :: D.Decoder s ScriptReply
scriptReplyDecoder = do
  count <- D.decodeListLen
  if count /= 3 then fail "Expected script reply" else ScriptReply <$> optional D.decodeBytes <*> D.decodeBytes <*> optional D.decodeBytes

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_transaction_collection_list"
  cList :: CUInt -> Int64 -> Word64 -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt

foreign import ccall safe "cometa_test_transaction_collection_script"
  cScript :: CUInt -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt
