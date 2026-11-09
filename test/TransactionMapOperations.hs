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

-- | Original differential tests against cardano-c c5edc7c8. Ordinary public
-- associations provide indexing/first lookup; native owners never cross FFI.
module TransactionMapOperations (tests) where

import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Read as R
import qualified Codec.CBOR.Term as T
import qualified Codec.CBOR.Write as W
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import qualified Cometa.Encoding.Collections as Collections
import qualified Cometa.PlutusData as Data
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.TransactionId as Id
import Control.Monad (forM_, (>=>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Either (isLeft)
import Data.List (find, sortOn)
import qualified Data.Text.Encoding as Text
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Transaction map operations"
    [ testCase "text withdrawal insertion retains duplicate and zero accounts" checkWithdrawals,
      testCase "deposit indexing follows reward bytes and insertion rejects duplicate keys" checkDeposits,
      testCase "interval indexed getters preserve exact and optional unsigned bounds" checkIntervals,
      testCase "guard indexed getters distinguish null from encoded data and key kinds" checkGuards,
      testCase "input redeemer associations retain duplicates, first lookup and independent clone" checkRedeemers,
      testCase "subtransaction lookup hashes bodies, rejects duplicate ids and retains found owner" checkSubtransactions
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

accounts :: IO [Reward.RewardAddress]
accounts = traverse (must . Reward.fromBytes) [B.cons tag (B.replicate 28 seed) | (tag, seed) <- [(241, 0), (224, 255), (225, 0), (240, 1)]]

encode :: E.Encoding -> ByteString
encode = W.toStrictByteString

raw :: ByteString -> E.Encoding
raw = E.encodePreEncoded

association :: (a -> E.Encoding) -> (b -> E.Encoding) -> [(a, b)] -> ByteString
association key value pairs = encode (E.encodeMapLen (fromIntegral (length pairs)) <> foldMap (\(k, v) -> key k <> value v) pairs)

interval :: Fields.BalanceInterval -> E.Encoding
interval (Fields.ExactBalance value) = E.encodeWord64 value
interval (Fields.BalanceRange lower upper) = E.encodeListLen 2 <> maybe E.encodeNull E.encodeWord64 lower <> maybe E.encodeNull E.encodeWord64 upper

term :: ByteString -> IO T.Term
term bytes = case R.deserialiseFromBytes T.decodeTerm (L.fromStrict bytes) of
  Left failure -> assertFailure (show failure) >> fail "reply"
  Right (rest, value) -> do
    rest @?= L.empty
    pure value

-- No unchecked (!!): host indexing validates exactly the native nonnegative
-- range. RewardAddress Ord is network-first, unlike native byte ordering.
at :: Int -> [a] -> Maybe a
at index values
  | index < 0 = Nothing
  | otherwise = case drop index values of [] -> Nothing; value : _ -> Just value

selected :: (a -> T.Term) -> (b -> T.Term) -> Maybe (a, b) -> T.Term
selected key value = maybe T.TNull (\(k, v) -> T.TList [key k, value v])

unsignedTerm :: Word64 -> T.Term
unsignedTerm amount
  | toInteger amount <= toInteger (maxBound :: Int) = T.TInt (fromIntegral amount)
  | otherwise = T.TInteger (toInteger amount)

reply :: Bool -> T.Term -> Int -> ByteString -> T.Term
reply inserted chosen count bytes = T.TList [T.TBool inserted, chosen, chosen, T.TInt count, T.TBytes bytes]

checkWithdrawals :: IO ()
checkWithdrawals = do
  keys <- accounts
  forM_ [[], [(head keys, 0)], zip keys [0, maxBound, 1, 2]] $ \source ->
    forM_ ["invalid", Reward.toText (head keys), Reward.toText (last keys)] $ \text -> do
      let encoded = Collections.encodeWithdrawalsCbor source
          parsed = Reward.fromText text
          expected = either (const source) (\key -> source <> [(key, maxBound)]) parsed
          final = Collections.encodeWithdrawalsCbor expected
      actual <- mapOracle withdrawal encoded (Text.encodeUtf8 text) maxBound B.empty 0 >>= must
      actual @?= reply (not (isLeft parsed)) T.TNull (length expected) final

checkDeposits :: IO ()
checkDeposits = do
  keys <- accounts
  forM_ [[], take 1 (zip keys [0 ..]), zip keys [0, maxBound, 1, 2]] $ \source -> do
    if null source
      then pure ()
      else do
        entries <- must (Fields.mkEntries source)
        sortOn (Reward.toBytes . fst) (Fields.entries entries) @?= sortOn (Reward.toBytes . fst) source
    assertBool "duplicate public deposit accepted" (isLeft (Fields.mkEntries (source <> source)) || null source)
    forM_ [B.empty, "invalid", Text.encodeUtf8 (Reward.toText (head keys)), Text.encodeUtf8 (Reward.toText (last keys))] $ \text -> do
      let parsed = Reward.fromText (Text.decodeUtf8 text)
          inserted = B.null text || either (const False) (\key -> all ((/= key) . fst) source) parsed
          extra = if B.null text || not inserted then [] else either (const []) (\key -> [(key, maxBound)]) parsed
          ordered = sortOn (Reward.toBytes . fst) (source <> extra)
          bytes = association (E.encodeBytes . Reward.toBytes) E.encodeWord64
      forM_ [0 .. length ordered + 1] $ \index -> do
        actual <- mapOracle deposit (bytes source) text maxBound B.empty index >>= must
        actual @?= reply inserted (selected (T.TBytes . Reward.toBytes) unsignedTerm (at index ordered)) (length ordered) (bytes ordered)

checkIntervals :: IO ()
checkIntervals = do
  keys <- accounts
  let intervals = [Fields.ExactBalance 0, Fields.ExactBalance maxBound, Fields.BalanceRange Nothing (Just maxBound), Fields.BalanceRange (Just 0) Nothing]
      bytes = association (E.encodeBytes . Reward.toBytes) interval
  forM_ [[], zip keys intervals] $ \source -> do
    if null source
      then pure ()
      else do
        entries <- must (Fields.mkEntries source)
        length (Fields.entries entries) @?= length source
    forM_ [B.empty, "invalid", Text.encodeUtf8 (Reward.toText (head keys)), Text.encodeUtf8 (Reward.toText (last keys))] $ \text -> do
      let parsed = Reward.fromText (Text.decodeUtf8 text)
          inserted = B.null text || either (const False) (\key -> all ((/= key) . fst) source) parsed
          extra = if B.null text || not inserted then [] else either (const []) (\key -> [(key, Fields.ExactBalance maxBound)]) parsed
          ordered = sortOn (Reward.toBytes . fst) (source <> extra)
      forM_ [0 .. length ordered + 1] $ \index -> do
        actual <- mapOracle balance (bytes source) text 0 (encode (interval (Fields.ExactBalance maxBound))) index >>= must
        actual @?= reply inserted (selected (T.TBytes . Reward.toBytes) (T.TBytes . encode . interval) (at index ordered)) (length ordered) (bytes ordered)

checkGuards :: IO ()
checkGuards = do
  key <- must (Credential.keyHashFromBytes (B.replicate 28 255))
  script <- must (Credential.scriptHashFromBytes (B.replicate 28 0))
  retained <- must (Data.decodeCbor (B.pack [24, 1]))
  let source = [(Credential.ScriptCredential script, Just retained), (Credential.KeyCredential key, Nothing)] :: [(Credential.Credential Credential.Guard, Maybe Data.EncodedPlutusData)]
      bytes = association (raw . Credential.encodeCbor) (maybe E.encodeNull (raw . Data.toCbor))
  entries <- must (Fields.mkEntries source)
  assertBool "duplicate public guards accepted" (isLeft (Fields.mkEntries (source <> source)))
  forM_ [[], Fields.entries entries] $ \pairs ->
    forM_ [0 .. length pairs + 1] $ \index -> do
      actual <- mapOracle guards (bytes pairs) B.empty 0 B.empty index >>= must
      actual @?= reply True (selected (T.TBytes . Credential.encodeCbor) (maybe T.TNull (T.TBytes . Data.toCbor)) (at index pairs)) (length pairs) (bytes pairs)

checkRedeemers :: IO ()
checkRedeemers = do
  identifiers <- traverse (must . Id.fromBytes . B.replicate 32) [0, 1, 2]
  retained <- must (Data.decodeCbor (B.pack [24, 1]))
  let inputs = map (`Input.input` 0) identifiers
      redeemers = [Redeemer.Redeemer Redeemer.Spending 3 retained (ExUnits 0 maxBound), Redeemer.Redeemer Redeemer.Rewarding 0 (Data.fromData (Data.Integer 2)) (ExUnits maxBound 0)]
      pairs = [(head inputs, head redeemers), (inputs !! 1, last redeemers), (head inputs, last redeemers)]
      encodePairs values = encode (E.encodeListLen (fromIntegral (length values)) <> foldMap (\(key, value) -> E.encodeListLen 2 <> raw (Input.encodeCbor key) <> raw (Redeemer.encodeCbor value)) values)
  forM_ [[], take 1 pairs, pairs, reverse pairs] $ \source ->
    forM_ inputs $ \query ->
      forM_ [0 .. length source + 1] $ \index -> do
        actual <- inputOracle (encodePairs source) (Input.encodeCbor query) index >>= must
        let found = lookup query source
            chosen = selected (T.TBytes . Input.encodeCbor) (T.TBytes . Redeemer.encodeCbor) (at index source)
        actual @?= T.TList [T.TInt (length source), maybe T.TNull (T.TBytes . Redeemer.encodeCbor) found, chosen, chosen]

checkSubtransactions :: IO ()
checkSubtransactions = do
  plainBody <- must (SubBody.fromBody (SubBody.body [] []))
  donatedBody <- must (SubBody.fromBody (SubBody.fromFields ((Fields.fields [] []) {Fields.fieldDonation = Just 0})))
  let values = [Sub.fromBody donatedBody, Sub.fromBody plainBody]
  ids <- traverse (Sub.transactionId >=> must) values
  missing <- must (Id.fromBytes (B.replicate 32 42))
  forM_ [[], values, reverse values] $ \source -> do
    tagged <- traverse (\value -> do identifier <- Sub.transactionId value >>= must; pure (identifier, value)) source
    forM_ (missing : ids) $ \identifier -> do
      let bytes = if null source then B.empty else encode (E.encodeTag 258 <> E.encodeListLen (fromIntegral (length source)) <> foldMap (raw . Sub.encodeCbor) source)
          expected = maybe (B.singleton 246) (Sub.encodeCbor . snd) (find ((== identifier) . fst) tagged)
      actual <- subOracle bytes (Id.toBytes identifier) >>= must
      actual @?= expected
  -- New empty sets are searchable, but empty CBOR imports are schema-invalid.
  subOracle (encode (E.encodeTag 258 <> E.encodeListLen 0)) (Id.toBytes missing) >>= assertBool "empty subtransaction set imported" . isLeft
  let duplicate = encode (E.encodeTag 258 <> E.encodeListLen 2 <> foldMap (raw . Sub.encodeCbor) [head values, head values])
  subOracle duplicate (Id.toBytes (head ids)) >>= assertBool "duplicate subtransaction ids imported" . isLeft

-- FFI ------------------------------------------------------------------------

type MapOperation = Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Word64 -> Ptr Word8 -> CSize -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt

foreign import ccall unsafe "cometa_test_withdrawal_operations" withdrawal :: MapOperation

foreign import ccall unsafe "cometa_test_direct_deposit_operations" deposit :: MapOperation

foreign import ccall unsafe "cometa_test_account_balance_intervals_operations" balance :: MapOperation

foreign import ccall unsafe "cometa_test_required_guards_operations" guards :: MapOperation

foreign import ccall unsafe "cometa_test_input_redeemer_operations" nativeInput :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt

foreign import ccall unsafe "cometa_test_subtransaction_find" nativeSub :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt

invoke :: (Ptr Word8 -> CSize -> Ptr CSize -> IO CInt) -> IO (Either String ByteString)
invoke operation = allocaBytes 65536 $ \output -> alloca $ \size -> do
  code <- operation output 65536 size
  if code /= 0
    then pure (Left ("native map status " <> show code))
    else do
      count <- peek size
      Right <$> B.packCStringLen (castPtr output, fromIntegral count)

mapOracle :: MapOperation -> ByteString -> ByteString -> Word64 -> ByteString -> Int -> IO (Either String T.Term)
mapOracle operation source text amount value index =
  B.useAsCStringLen source $ \(input, inputSize) -> B.useAsCStringLen text $ \(key, keySize) -> B.useAsCStringLen value $ \(argument, argumentSize) -> do
    result <- invoke (operation (castPtr input) (fromIntegral inputSize) (castPtr key) (fromIntegral keySize) amount (castPtr argument) (fromIntegral argumentSize) (fromIntegral index))
    traverse term result

inputOracle :: ByteString -> ByteString -> Int -> IO (Either String T.Term)
inputOracle source query index = B.useAsCStringLen source $ \(input, size) -> B.useAsCStringLen query $ \(target, targetSize) -> do
  result <- invoke (nativeInput (castPtr input) (fromIntegral size) (castPtr target) (fromIntegral targetSize) (fromIntegral index))
  traverse term result

subOracle :: ByteString -> ByteString -> IO (Either String ByteString)
subOracle source query = B.useAsCStringLen source $ \(input, size) -> B.useAsCStringLen query $ \(target, targetSize) ->
  invoke (nativeSub (castPtr input) (fromIntegral size) (castPtr target) (fromIntegral targetSize))
