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

-- | Standalone set representation choices preserve exact nested payloads.
-- Tests are original Cometa fixtures; native comparisons reuse the existing
-- certificate, proposal and pool reconstruction oracles.
module StandaloneSetEncoding (tests) where

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import Cometa.Encoding.Set (SetEncoding (..))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.NetworkId as Network
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.UnitInterval as Unit
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import qualified Data.Set as Set
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Ptr (Ptr, castPtr)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Standalone set encoding"
    [ testCase "certificate tags retain indefinite arrays and nonminimal nested bytes" checkCertificates,
      testCase "proposal tags retain ordering, duplicates and exact nested bytes" checkProposals,
      testCase "pool owner encoding is an explicit fresh serialization choice" checkPool,
      testCase "committee removal tags retain imported credential order and bytes" checkRemovals
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "Invalid fixture") pure

tags :: [ByteString]
tags = [B.pack [217, 1, 2], B.pack [218, 0, 0, 1, 2], B.pack [219, 0, 0, 0, 0, 0, 0, 1, 2]]

checkCertificates :: IO ()
checkCertificates = do
  stake <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  let value = Certificate.StakeRegistration (Credential.KeyCredential stake)
      collection = Certificates.fromList [value, value]
      -- Deliberately nonminimal certificate kind, inside an indefinite collection.
      item = B.pack [130, 24, 0] <> B.drop 2 (Certificate.encodeCbor value)
      payload = B.singleton 159 <> item <> item <> B.singleton 255
  nativeAgreement cCertificates 1 (Certificates.encodeCborWith TaggedSet collection)
  forM_ tags $ \tag -> do
    original <- must (Certificates.decodeCbor (tag <> payload))
    Certificates.setEncoding original @?= TaggedSet
    Certificates.withSetEncoding TaggedSet original @?= original
    let changed = Certificates.withSetEncoding UntaggedSet original
    Certificates.toCbor changed @?= payload
    Certificates.toCertificates changed @?= collection
    Certificates.decodeCbor payload @?= Right changed
    Certificates.withSetEncoding UntaggedSet changed @?= changed
    Certificates.toCbor original @?= tag <> payload
  forM_ [TaggedSet, UntaggedSet] $ \requested -> do
    encoded <- must (Certificates.decodeCbor (Certificates.encodeCborWith requested collection))
    Certificates.setEncoding encoded @?= requested
    Certificates.toCertificates encoded @?= collection
  assertBool "wrong set tag" (isLeft (Certificates.decodeCbor (B.pack [217, 1, 3, 128])))

checkProposals :: IO ()
checkProposals = do
  stake <- must (Credential.keyHashFromBytes (B.replicate 28 1))
  url <- must (Anchor.mkUrl "https://example.com")
  digest <- must (Anchor.dataHashFromBytes (B.replicate 32 2))
  let account = Reward.fromCredential Network.testnet (Credential.KeyCredential stake)
      value = Proposal.Proposal 0 account Action.InfoAction (Anchor.Anchor url digest)
      collection = Proposal.fromList [value, value]
      -- Deliberately nonminimal deposit, preserved below the outer collection.
      item = B.pack [132, 24, 0] <> B.drop 2 (Proposal.encodeCbor value)
      payload = B.singleton 159 <> item <> item <> B.singleton 255
  nativeAgreement cProposals 11 (Proposal.encodeProposalsWith TaggedSet collection)
  forM_ tags $ \tag -> do
    original <- must (Proposal.decodeProposals (tag <> payload))
    Proposal.withSetEncoding TaggedSet original @?= original
    let changed = Proposal.withSetEncoding UntaggedSet original
    Proposal.proposalsCbor changed @?= payload
    Proposal.toProposals changed @?= collection
    Proposal.decodeProposals payload @?= Right changed
    Proposal.withSetEncoding UntaggedSet changed @?= changed
    Proposal.proposalsCbor original @?= tag <> payload
  forM_ [TaggedSet, UntaggedSet] $ \requested -> do
    encoded <- must (Proposal.decodeProposals (Proposal.encodeProposalsWith requested collection))
    Proposal.setEncoding encoded @?= requested
    Proposal.toProposals encoded @?= collection
  assertBool "wrong set tag" (isLeft (Proposal.decodeProposals (B.pack [217, 1, 3, 128])))

checkPool :: IO ()
checkPool = do
  operator <- must (Credential.keyHashFromBytes (B.replicate 28 3))
  stake <- must (Credential.keyHashFromBytes (B.replicate 28 4))
  vrf <- must (Pool.vrfKeyHashFromBytes (B.replicate 32 5))
  margin <- must (Unit.mkUnitInterval 1 2)
  let account = Reward.fromCredential Network.testnet (Credential.KeyCredential stake)
      value = Pool.PoolParameters operator vrf Nothing 0 0 margin account (Set.singleton stake) [] Nothing
  Pool.encodeCborWith TaggedSet value @?= Pool.encodeCbor value
  let tagged = Pool.encodeCbor value
      untagged = Pool.encodeCborWith UntaggedSet value
      (prefix, suffix) = B.breakSubstring (B.pack [217, 1, 2]) tagged
  assertBool "owner tag exists" (not (B.null suffix))
  untagged @?= prefix <> B.drop 3 suffix
  Pool.decodeCbor untagged @?= Right value
  Pool.decodeCbor tagged @?= Right value
  nativeAgreement cPool 0 tagged
  forM_ tags $ \tag -> Pool.decodeCbor (prefix <> tag <> B.drop 3 suffix) @?= Right value

checkRemovals :: IO ()
checkRemovals = do
  first <- must (Credential.keyHashFromBytes (B.replicate 28 9))
  second <- must (Credential.keyHashFromBytes (B.replicate 28 1))
  let credential hash = B.pack [130, 24, 0, 88, 28] <> Credential.keyHashBytes hash
      -- Retain unsorted input order and repeated credentials in the exact bytes.
      payload = B.singleton 159 <> credential first <> credential second <> credential first <> B.singleton 255
      values = Action.removalsFromList (map Credential.KeyCredential [first, second, first])
  forM_ tags $ \tag -> do
    original <- must (Action.decodeRemovals (tag <> payload))
    Action.removalsSetEncoding original @?= TaggedSet
    Action.withRemovalsSetEncoding TaggedSet original @?= original
    let changed = Action.withRemovalsSetEncoding UntaggedSet original
    Action.removalsCbor changed @?= payload
    Action.toRemovals changed @?= values
    Action.decodeRemovals payload @?= Right changed
    Action.withRemovalsSetEncoding UntaggedSet changed @?= changed
  forM_ [TaggedSet, UntaggedSet] $ \requested -> do
    encoded <- must (Action.decodeRemovals (Action.encodeRemovalsWith requested values))
    Action.removalsSetEncoding encoded @?= requested
    Action.toRemovals encoded @?= values
  forM_ [B.pack [217, 1, 3, 128], B.pack [128, 0], B.pack [129, 128]] $ \invalid ->
    assertBool "invalid credential set" (isLeft (Action.decodeRemovals invalid))

nativeAgreement :: (CUInt -> Ptr Word8 -> CSize -> IO CInt) -> CUInt -> ByteString -> IO ()
nativeAgreement oracle mode bytes = B.useAsCStringLen bytes $ \(pointer, size) -> do
  result <- oracle mode (castPtr pointer) (fromIntegral size)
  result @?= 1

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_certificates_agree"
  cCertificates :: CUInt -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall unsafe "cometa_test_proposals_agreement"
  cProposals :: CUInt -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall safe "cometa_test_pool_agreement"
  cPool :: CUInt -> Ptr Word8 -> CSize -> IO CInt
