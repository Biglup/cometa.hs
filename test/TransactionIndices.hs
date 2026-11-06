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

module TransactionIndices (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Address as Address
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Indices as Indices
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.TransactionId as TxId
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Transaction indices"
    [ testCase "sorted input and reference positions agree with native" inputs,
      testCase "output order, address and minimum agree with native" outputs,
      testCase "zero and empty imported mint policies retain positions" mintPolicies,
      testCase "absent collections and unsigned output threshold boundaries" absent
    ]

-- Intentionally noncanonical input/policy order, repeated spending reference,
-- empty and zero-only policies. These public decoded values retain exact bytes.
fixture :: IO Tx.Transaction
fixture = require (Tx.decodeCbor (Cbor.encode encoding))
  where
    encoding = E.encodeListLen 4 <> body <> E.encodeMapLen 0 <> E.encodeBool True <> E.encodeNull
    body =
      E.encodeMapLen 5
        <> E.encodeWord 0
        <> inputSet [(2, 0), (1, 256), (1, 24), (1, 24)]
        <> E.encodeWord 1
        <> E.encodeListLen 3
        <> output 0 2
        <> output 1 10
        <> output 0 10
        <> E.encodeWord 2
        <> E.encodeWord 0
        <> E.encodeWord 9
        <> E.encodeMapLen 3
        <> E.encodeBytes (policyBytes 3)
        <> E.encodeMapLen 1
        <> E.encodeBytes B.empty
        <> E.encodeInt (-2)
        <> E.encodeBytes (policyBytes 1)
        <> E.encodeMapLen 0
        <> E.encodeBytes (policyBytes 2)
        <> E.encodeMapLen 1
        <> E.encodeBytes B.empty
        <> E.encodeWord 0
        <> E.encodeWord 18
        <> inputSet [(2, 1), (1, 256), (1, 24)]
    inputSet values = E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap reference values
    reference (seed, index) = E.encodeListLen 2 <> E.encodeBytes (idBytes seed) <> E.encodeWord64 index
    output seed amount = E.encodeListLen 2 <> E.encodeBytes (addressBytes seed) <> E.encodeWord amount

inputs :: IO ()
inputs = do
  transaction <- fixture
  forM_ [(1, 24, Just 0, Just 0), (1, 256, Just 2, Just 1), (2, 0, Just 3, Nothing), (2, 1, Nothing, Just 2), (3, 0, Nothing, Nothing)] $ \(seed, index, spend, reference) -> do
    identifier <- require (TxId.fromBytes (idBytes seed))
    let key = Input.input identifier index
    Indices.findInput key transaction @?= spend
    Indices.findReferenceInput key transaction @?= reference
    native transaction 0 (idBytes seed) index >>= (@?= spend)
    native transaction 1 (idBytes seed) index >>= (@?= reference)

outputs :: IO ()
outputs = do
  transaction <- fixture
  forM_ [(0, 0, Just 0), (0, 2, Just 0), (0, 3, Just 2), (0, 10, Just 2), (0, 11, Nothing), (1, 10, Just 1), (2, 0, Nothing)] $ \(seed, minimumLovelace, expected) -> do
    destination <- require (Address.fromBytes (addressBytes seed))
    Indices.findOutput destination minimumLovelace transaction @?= expected
    native transaction 2 (addressBytes seed) minimumLovelace >>= (@?= expected)

mintPolicies :: IO ()
mintPolicies = do
  let duplicatePolicies =
        Cbor.encode
          ( E.encodeListLen 4
              <> E.encodeMapLen 4
              <> E.encodeWord 0
              <> E.encodeListLen 0
              <> E.encodeWord 1
              <> E.encodeListLen 0
              <> E.encodeWord 2
              <> E.encodeWord 0
              <> E.encodeWord 9
              <> E.encodeMapLen 2
              <> E.encodeBytes (policyBytes 1)
              <> E.encodeMapLen 0
              <> E.encodeBytes (policyBytes 1)
              <> E.encodeMapLen 0
              <> E.encodeMapLen 0
              <> E.encodeBool True
              <> E.encodeNull
          )
  assertBool "duplicate imported policy keys rejected" (isLeft (Tx.decodeCbor duplicatePolicies))
  transaction <- fixture
  forM_ [(1, Just 0), (2, Just 1), (3, Just 2), (4, Nothing)] $ \(seed, expected) -> do
    policy <- require (Policy.fromBytes (policyBytes seed))
    Indices.findMintPolicy policy transaction @?= expected
    native transaction 3 (policyBytes seed) 0 >>= (@?= expected)

absent :: IO ()
absent = do
  body <- require (Body.fromBody (Body.body [] [] 0))
  let transaction = Tx.fromBody body
  identifier <- require (TxId.fromBytes (idBytes 1))
  policy <- require (Policy.fromBytes (policyBytes 1))
  destination <- require (Address.fromBytes (addressBytes 0))
  Indices.findInput (Input.input identifier 0) transaction @?= Nothing
  Indices.findReferenceInput (Input.input identifier 0) transaction @?= Nothing
  Indices.findOutput destination 0 transaction @?= Nothing
  Indices.findMintPolicy policy transaction @?= Nothing
  populated <- fixture
  Indices.findOutput destination 9223372036854775808 populated @?= Nothing
  Indices.findOutput destination maxBound populated @?= Nothing
  native populated 2 (addressBytes 0) 9223372036854775807 >>= (@?= Nothing)

idBytes :: Word8 -> ByteString
idBytes = B.replicate 32

policyBytes :: Word8 -> ByteString
policyBytes = B.replicate 28

addressBytes :: Word8 -> ByteString
addressBytes seed = B.cons 0x60 (B.replicate 28 seed)

require :: (Show error) => Either error value -> IO value
require = either (\failure -> assertFailure (show failure) >> fail "invalid fixture") pure

native :: Tx.Transaction -> CUInt -> ByteString -> Word64 -> IO (Maybe Word64)
native transaction operation key argument =
  B.useAsCStringLen (Tx.encodeCbor transaction) $ \(bytes, size) ->
    B.useAsCStringLen key $ \(keyBytes, keySize) -> alloca $ \result -> do
      status <- cIndex (castPtr bytes) (fromIntegral size) operation (castPtr keyBytes) (fromIntegral keySize) argument result
      if status == 0
        then Just <$> peek result
        else do
          -- CARDANO_ERROR_ELEMENT_NOT_FOUND, lib/include/cardano/error.h.
          status @?= 9
          pure Nothing

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_transaction_index"
  cIndex :: Ptr Word8 -> CSize -> CUInt -> Ptr Word8 -> CSize -> Word64 -> Ptr Word64 -> IO CUInt
