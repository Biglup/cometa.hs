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

-- | Certificate schema, constructor boundaries and native reconstruction tests.
module Certificates (tests, sampleCertificates) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Write as Write
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.NetworkId as Network
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.UnitInterval as UnitInterval
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
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

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Certificates"
    [ testCase "all certificate alternatives and uint64 boundaries reconstruct natively" checkAlternatives,
      testCase "pinned native certificate corpus reconstructs semantic public data" checkPinned,
      testCase "exact envelopes preserve nonminimal and indefinite encodings" checkExact,
      testCase "malformed schemas, duplicate rewards and signed MIR amounts fail" checkInvalid,
      testCase "collection order, duplicates and optional set tag are preserved" checkCollections,
      testCase "repeated native reconstruction releases retained fields" checkRepeated,
      testProperty "all generated typed certificates round trip and reconstruct natively" propRoundTrip
    ]

sampleCertificates :: Word8 -> Word64 -> Either Error [Certificate.Certificate]
sampleCertificates seed amount = do
  stakeKey <- key seed
  poolKey <- key (seed + 1)
  drepKey <- key (seed + 2)
  coldKey <- key (seed + 3)
  hotKey <- key (seed + 4)
  genesisKey <- key (seed + 5)
  delegateKey <- key (seed + 6)
  script <- Credential.scriptHashFromBytes (ByteString.replicate 28 (seed + 7))
  vrf <- Pool.vrfKeyHashFromBytes (ByteString.replicate 32 seed)
  margin <- UnitInterval.mkUnitInterval 1 5
  location <- Anchor.mkUrl "https://example.com/certificate.json"
  digest <- Anchor.dataHashFromBytes (ByteString.replicate 32 (seed + 8))
  let stake = Credential.KeyCredential stakeKey
      drepCredential = Credential.KeyCredential drepKey
      cold = Credential.KeyCredential coldKey
      hot = Credential.KeyCredential hotKey
      target = DRep.DRepCredential drepCredential
      anchor = Just (Anchor.Anchor location digest)
      parameters = Pool.PoolParameters poolKey vrf Nothing amount amount margin (Reward.fromCredential Network.testnet stake) (Set.singleton stakeKey) [] Nothing
  pure
    [ Certificate.StakeRegistration stake,
      Certificate.StakeDeregistration stake,
      Certificate.StakeDelegation stake poolKey,
      Certificate.PoolRegistration parameters,
      Certificate.PoolRetirement poolKey amount,
      Certificate.GenesisKeyDelegation genesisKey delegateKey vrf,
      Certificate.MoveInstantaneousRewards (Certificate.ToOtherPot Certificate.Reserves amount),
      Certificate.MoveInstantaneousRewards (Certificate.ToOtherPot Certificate.Treasury amount),
      Certificate.MoveInstantaneousRewards (Certificate.ToStakeCredentials Certificate.Reserves (Map.fromList [(stake, amount), (Credential.ScriptCredential script, amount)])),
      Certificate.MoveInstantaneousRewards (Certificate.ToStakeCredentials Certificate.Treasury Map.empty),
      Certificate.Registration stake amount,
      Certificate.Unregistration stake amount,
      Certificate.VoteDelegation stake target,
      Certificate.VoteDelegation (Credential.ScriptCredential script) DRep.AlwaysAbstain,
      Certificate.VoteDelegation stake DRep.AlwaysNoConfidence,
      Certificate.StakeVoteDelegation stake poolKey target,
      Certificate.StakeRegistrationDelegation stake poolKey amount,
      Certificate.VoteRegistrationDelegation stake target amount,
      Certificate.StakeVoteRegistrationDelegation stake poolKey target amount,
      Certificate.AuthorizeCommitteeHot cold hot,
      Certificate.AuthorizeCommitteeHot (Credential.ScriptCredential script) (Credential.ScriptCredential script),
      Certificate.ResignCommitteeCold cold Nothing,
      Certificate.ResignCommitteeCold cold anchor,
      Certificate.RegisterDRep drepCredential amount Nothing,
      Certificate.RegisterDRep (Credential.ScriptCredential script) amount anchor,
      Certificate.UnregisterDRep drepCredential amount,
      Certificate.UpdateDRep drepCredential Nothing,
      Certificate.UpdateDRep drepCredential anchor
    ]

key :: Word8 -> Either Error (Credential.KeyHash purpose)
key = Credential.keyHashFromBytes . ByteString.replicate 28

checkAlternatives :: IO ()
checkAlternatives = forM_ [0, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296, maxBound] $ \amount -> do
  values <- expectRight (sampleCertificates 11 amount)
  forM_ values checkCertificate

checkCertificate :: Certificate.Certificate -> IO ()
checkCertificate value = do
  let encoded = Certificate.encodeCbor value
  reloaded <- expectRight (Certificate.decodeCbor encoded)
  Certificate.toCertificate reloaded @?= value
  Certificate.toCbor reloaded @?= encoded
  Certificate.toCertificate (Certificate.fromCertificate value) @?= value
  nativeAgreement 0 encoded

checkPinned :: IO ()
checkPinned = forM_ pinnedVectors $ \(_, fixture) -> do
  encoded <- bytes fixture
  reloaded <- expectRight (Certificate.decodeCbor encoded)
  let value = Certificate.toCertificate reloaded
  checkCertificate value
  -- Null BLS placeholders are semantic omission and re-encode without the slot.
  Certificate.toCbor reloaded @?= encoded

checkExact :: IO ()
checkExact = do
  authority <- expectRight (key 0)
  let value = Certificate.Registration (Credential.KeyCredential authority) 0
      canonical = Certificate.encodeCbor value
      nonminimal = ByteString.pack [0x9f, 0x18, 7] <> ByteString.take (ByteString.length canonical - 3) (ByteString.drop 2 canonical) <> ByteString.pack [0x18, 0, 0xff]
      -- Build indefinite form directly so its accepted structure is explicit.
      imported = ByteString.pack [0x9f, 0x18, 7] <> ByteString.take 32 (ByteString.drop 2 canonical) <> ByteString.pack [0x18, 0, 0xff]
  nonminimal @?= imported
  reloaded <- expectRight (Certificate.decodeCbor imported)
  Certificate.toCertificate reloaded @?= value
  Certificate.toCbor reloaded @?= imported
  Certificate.encodeCbor (Certificate.toCertificate reloaded) @?= canonical
  assertBool "byte-sensitive exact envelopes" (reloaded /= Certificate.fromCertificate value)

checkInvalid :: IO ()
checkInvalid = do
  authority <- expectRight (key 0)
  let stake = Credential.KeyCredential authority
      credential = Encode.encodeListLen 2 <> Encode.encodeWord 0 <> Encode.encodeBytes (Credential.keyHashBytes authority)
      duplicateMir = Encode.encodeListLen 2 <> Encode.encodeWord 6 <> Encode.encodeListLen 2 <> Encode.encodeWord 0 <> Encode.encodeMapLen 2 <> credential <> Encode.encodeWord 1 <> credential <> Encode.encodeWord 2
      signedMir = Encode.encodeListLen 2 <> Encode.encodeWord 6 <> Encode.encodeListLen 2 <> Encode.encodeWord 0 <> Encode.encodeMapLen 1 <> credential <> Encode.encodeInteger (-1)
      overflow = Encode.encodeListLen 3 <> Encode.encodeWord 7 <> credential <> Encode.encodeInteger (2 ^ (64 :: Int))
  forM_ ["", "80", "8100", "8200", "820013", "82138200581c", "82008202581c", "83078200581b00000000000000000000000000000000000000000000000000000000"] $ \fixture -> do
    malformed <- bytes fixture
    assertBool "invalid certificate schema" (isLeft (Certificate.decodeCbor malformed))
  forM_ [duplicateMir, signedMir, overflow] $ \malformed -> assertBool "invalid rewards or bound" (isLeft (Certificate.decodeCbor (Write.toStrictByteString malformed)))
  let valid = Certificate.encodeCbor (Certificate.StakeRegistration stake)
  assertBool "trailing data" (isLeft (Certificate.decodeCbor (valid <> "\NUL")))
  assertBool "wrong collection tag" (isLeft (Certificates.decodeCbor (ByteString.pack [0xd9, 1, 3, 0x80])))

checkCollections :: IO ()
checkCollections = do
  values <- expectRight (sampleCertificates 9 1000)
  let ordered = values <> take 2 values
      collection = Certificates.fromList ordered
      encoded = Certificates.encodeCbor collection
      untagged = ByteString.drop 3 encoded
  reloaded <- expectRight (Certificates.decodeCbor encoded)
  Certificates.toList (Certificates.toCertificates reloaded) @?= ordered
  Certificates.toCbor reloaded @?= encoded
  Certificates.toCertificates (Certificates.fromCertificates collection) @?= collection
  untaggedValue <- expectRight (Certificates.decodeCbor untagged)
  Certificates.toCertificates untaggedValue @?= collection
  Certificates.toCbor untaggedValue @?= untagged
  nativeAgreement 1 encoded
  nativeAgreement 1 (Certificates.encodeCbor Certificates.empty)

checkRepeated :: IO ()
checkRepeated = do
  values <- expectRight (sampleCertificates 8 maxBound)
  replicateM_ 20 (forM_ values (nativeAgreement 0 . Certificate.encodeCbor))

propRoundTrip :: Property
propRoundTrip = property $ do
  seed <- forAll (Gen.word8 Range.constantBounded)
  amount <- forAll (Gen.word64 Range.constantBounded)
  values <- evalEither (sampleCertificates seed amount)
  forM_ values $ \value -> do
    let encoded = Certificate.encodeCbor value
    reloaded <- evalEither (Certificate.decodeCbor encoded)
    Certificate.toCertificate reloaded === value
    evalIO (nativeAgreement 0 encoded)
  let collection = Certificates.fromList values
  reloaded <- evalEither (Certificates.decodeCbor (Certificates.encodeCbor collection))
  Certificates.toCertificates reloaded === collection
  evalIO (nativeAgreement 1 (Certificates.encodeCbor collection))

nativeAgreement :: CUInt -> ByteString -> IO ()
nativeAgreement mode encoded = ByteString.useAsCStringLen encoded $ \(input, size) -> do
  agrees <- cAgreement mode (castPtr input) (fromIntegral size)
  agrees @?= 1

bytes :: String -> IO ByteString
bytes encoded = case Hex.decodeHex (Text.pack encoded) of
  Nothing -> assertFailure "invalid fixture hexadecimal" >> fail "unreachable assertion"
  Just value -> pure value

expectRight :: (Show failure) => Either failure value -> IO value
expectRight result = case result of
  Left failure -> assertFailure (show failure) >> fail "unreachable assertion"
  Right value -> pure value

-- Pinned Apache-2.0 cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/certs/*.cpp constants, retaining source filename and constant name.
-- Native constructor/getter agreement is checked after public semantic decoding;
-- generated public constructors above independently exercise field marshaling.
pinnedVectors :: [(String, String)]
pinnedVectors =
  [ ("auth_committee_hot_cert.cpp/CBOR", "830e8200581c000000000000000000000000000000000000000000000000000000008200581c00000000000000000000000000000000000000000000000000000000"),
    ("genesis_key_delegation_cert.cpp/CBOR", "8405581c00010001000100010001000100010001000100010001000100010001581c0002000200020002000200020002000200020002000200020002000258200003000300030003000300030003000300030003000300030003000300030003"),
    ("mir_cert.cpp/CBOR_USE_RESERVES_TO_POT", "820682001a000f4240"),
    ("mir_cert.cpp/CBOR_USE_TREASURY_TO_POT", "820682011a000f4240"),
    ("mir_cert.cpp/CBOR_USE_RESERVES_TO_CREDS", "82068200a18200581c0101010101010101010101010101010101010101010101010101010100"),
    ("mir_cert.cpp/CBOR_USE_TREASURY_TO_CREDS", "82068201a18200581c0101010101010101010101010101010101010101010101010101010100"),
    ("pool_registration_cert.cpp/CBOR", "8a03581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef9258208dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db01927101903e8d81e820105581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810fd9010281581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8383011913886b6578616d706c652e636f6d8400191770447f000001f682026b6578616d706c652e636f6d827368747470733a2f2f6578616d706c652e636f6d58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"),
    ("pool_registration_cert.cpp/CBOR_WITH_BLS_KEY", "8b03581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef9258208dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db0825860000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f5830606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f1927101903e8d81e820105581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810fd9010281581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8383011913886b6578616d706c652e636f6d8400191770447f000001f682026b6578616d706c652e636f6d827368747470733a2f2f6578616d706c652e636f6d58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"),
    ("pool_registration_cert.cpp/CBOR_WITH_NULL_BLS_KEY", "8b03581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef9258208dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db0f61927101903e8d81e820105581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810fd9010281581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8383011913886b6578616d706c652e636f6d8400191770447f000001f682026b6578616d706c652e636f6d827368747470733a2f2f6578616d706c652e636f6d58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"),
    ("pool_retirement_cert.cpp/CBOR", "8304581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef921903e8"),
    ("register_drep_cert.cpp/CBOR", "84108200581c0000000000000000000000000000000000000000000000000000000000f6"),
    ("register_drep_cert.cpp/CBOR_WITH_ANCHOR", "84108200581c0000000000000000000000000000000000000000000000000000000000827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000"),
    ("registration_cert.cpp/CBOR", "83078200581c0000000000000000000000000000000000000000000000000000000000"),
    ("registration_cert.cpp/CBOR_WITH_NONZERO_DEPOSIT", "83078200581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f1a001e8480"),
    ("resign_committee_cold_cert.cpp/CBOR", "830f8200581c00000000000000000000000000000000000000000000000000000000f6"),
    ("resign_committee_cold_cert.cpp/CBOR_WITH_ANCHOR", "830f8200581c00000000000000000000000000000000000000000000000000000000827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000"),
    ("stake_delegation_cert.cpp/CBOR", "83028200581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef92"),
    ("stake_deregistration_cert.cpp/CBOR", "82018200581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f"),
    ("stake_registration_cert.cpp/CBOR", "82008200581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f"),
    ("stake_registration_delegation_cert.cpp/CBOR", "840b8200581c00000000000000000000000000000000000000000000000000000000581c0000000000000000000000000000000000000000000000000000000000"),
    ("stake_vote_delegation_cert.cpp/CBOR", "840a8200581c00000000000000000000000000000000000000000000000000000000581c000000000000000000000000000000000000000000000000000000008200581c00000000000000000000000000000000000000000000000000000000"),
    ("stake_vote_registration_delegation_cert.cpp/CBOR", "850d8200581c00000000000000000000000000000000000000000000000000000000581c000000000000000000000000000000000000000000000000000000008200581c0000000000000000000000000000000000000000000000000000000000"),
    ("unregister_drep_cert.cpp/CBOR", "83118200581c0000000000000000000000000000000000000000000000000000000000"),
    ("unregistration_cert.cpp/CBOR", "83088200581c0000000000000000000000000000000000000000000000000000000000"),
    ("unregistration_cert.cpp/CBOR_WITH_NONZERO_DEPOSIT", "83088200581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f1a001e8480"),
    ("update_drep_cert.cpp/CBOR", "83128200581c00000000000000000000000000000000000000000000000000000000f6"),
    ("update_drep_cert.cpp/CBOR_WITH_ANCHOR", "83128200581c00000000000000000000000000000000000000000000000000000000827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000"),
    ("vote_delegation_cert.cpp/CBOR", "83098200581c000000000000000000000000000000000000000000000000000000008200581c00000000000000000000000000000000000000000000000000000000"),
    ("vote_registration_delegation_cert.cpp/CBOR", "840c8200581c000000000000000000000000000000000000000000000000000000008200581c0000000000000000000000000000000000000000000000000000000000")
  ]

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_certificates_agree"
  cAgreement :: CUInt -> Ptr Word8 -> CSize -> IO CInt
