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

-- | Typed pool workflows, pinned native vectors and reconstruction properties.
module Pool (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.NetworkId as Network
import qualified Cometa.Pool.BlsKey as Bls
import qualified Cometa.Pool.Metadata as Metadata
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Pool.Relay as Relay
import qualified Cometa.UnitInterval as Unit
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import Data.Maybe (isNothing)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Word (Word8)
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
    "Pools"
    [ testCase "public fields reconstruct pinned native registration variants" checkPinned,
      testCase "all relay alternatives and optional IP/port combinations" checkRelays,
      testCase "byte, UTF-8, hash, URL and DNS boundaries" checkValidation,
      testCase "malformed CBOR, duplicate owners and trailing data" checkInvalid,
      testCase "semantic update independence and collection semantics" checkIndependence,
      testCase "repeated native reconstruction releases getter references" checkRepeated,
      testProperty "generated typed pool values agree with native field reconstruction" propParameters,
      testProperty "IPv4 and IPv6 text round trips preserve network bytes" propIpText
    ]

sample :: Either Error Pool.PoolParameters
sample = do
  poolOperator <- Credential.keyHashFromBytes =<< hex "d85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef92"
  vrf <- Pool.vrfKeyHashFromBytes =<< hex "8dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db0"
  stake <- Credential.keyHashFromBytes =<< hex "cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f"
  proportion <- Unit.mkUnitInterval 1 5
  dns <- Relay.mkDnsName "example.com"
  ipv4 <- Relay.ipv4FromText "127.0.0.1"
  Pool.PoolParameters poolOperator vrf Nothing 10000 1000 proportion (Reward.fromCredential Network.mainnet (Credential.KeyCredential stake)) (Set.singleton stake) [Relay.SingleHostName (Just 5000) dns, Relay.SingleHostAddress (Just 6000) (Just ipv4) Nothing, Relay.MultiHostName dns] . Just <$> sampleMetadata

sampleMetadata :: Either Error Metadata.Metadata
sampleMetadata = do
  location <- Metadata.mkUrl "https://example.com"
  digest <- Metadata.metadataHashFromBytes =<< hex "0f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"
  pure (Metadata.Metadata location digest)

sampleBls :: Either Error Bls.BlsKey
sampleBls = Bls.mkBlsKey (ByteString.pack [0 .. 95]) (ByteString.pack [96 .. 143])

checkPinned :: IO ()
checkPinned = do
  value <- expectRight sample
  bls <- expectRight sampleBls
  forM_ [(value, nativeParameters), (value {Pool.metadata = Nothing}, nativeNoMetadata), (value {Pool.blsKey = Just bls}, nativeWithBls)] $ \(parameters, vector) -> do
    golden <- expectRight (hex vector)
    Pool.encodeCbor parameters @?= ByteString.cons (if isNothing (Pool.blsKey parameters) then 0x89 else 0x8a) golden
    Pool.decodeCbor (Pool.encodeCbor parameters) @?= Right parameters
    nativeAgreement 0 (Pool.encodeCbor parameters)
  reference <- expectRight sampleMetadata
  goldenMetadata <- expectRight (hex nativeMetadata)
  Metadata.encodeCbor reference @?= goldenMetadata
  nativeAgreement 2 goldenMetadata
  goldenBls <- expectRight (hex nativeBls)
  Bls.encodeCbor bls @?= goldenBls
  nativeAgreement 3 goldenBls
  nullBls <- expectRight (hex nativeNullBls)
  Pool.decodeCbor (ByteString.cons 0x8a nullBls) @?= Right value
  let indefinite = ByteString.cons 0x9f (ByteString.snoc (ByteString.drop 1 (Pool.encodeCbor value)) 0xff)
  Pool.decodeCbor indefinite @?= Right value

checkRelays :: IO ()
checkRelays = do
  ipv4 <- expectRight (Relay.ipv4FromText "10.3.2.10")
  ipv6 <- expectRight (Relay.ipv6FromText "0102:0304:0102:0304:0102:0304:0102:0304")
  dns <- expectRight (Relay.mkDnsName "example.com")
  let values = [Relay.SingleHostAddress port v4 v6 | port <- [Nothing, Just 0, Just maxBound], v4 <- [Nothing, Just ipv4], v6 <- [Nothing, Just ipv6]] ++ [Relay.SingleHostName Nothing dns, Relay.SingleHostName (Just 10) dns, Relay.MultiHostName dns]
  forM_ values $ \value -> do
    Relay.decodeCbor (Relay.encodeCbor value) @?= Right value
    nativeAgreement 1 (Relay.encodeCbor value)
  forM_ [(Relay.SingleHostName (Just 10) dns, "83010a6b6578616d706c652e636f6d"), (Relay.MultiHostName dns, "82026b6578616d706c652e636f6d"), (Relay.SingleHostAddress (Just 10) (Just ipv4) (Just ipv6), "84000a440a03020a5001020304010203040102030401020304")] $ \(value, vector) -> do
    golden <- expectRight (hex vector)
    Relay.encodeCbor value @?= golden

checkValidation :: IO ()
checkValidation = do
  expectedDigest <- expectRight (hex "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
  hashResult <- Metadata.hashData "abc"
  fmap Metadata.metadataHashBytes hashResult @?= Right expectedDigest
  forM_ [0, 1, 27, 29, 31, 33, 96] $ \size -> do
    assertBool "VRF hash length" (isLeft (Pool.vrfKeyHashFromBytes (ByteString.replicate size 0)))
    assertBool "metadata hash length" (isLeft (Metadata.metadataHashFromBytes (ByteString.replicate size 0)))
  forM_ [0, 3, 5, 16] $ \size -> assertBool "IPv4 exact length" (isLeft (Relay.ipv4FromBytes (ByteString.replicate size 0)))
  forM_ [0, 4, 15, 17] $ \size -> assertBool "IPv6 exact length" (isLeft (Relay.ipv6FromBytes (ByteString.replicate size 0)))
  forM_ ["1.2.3", "1.2.3.256", "+1.2.3.4", "1.2.3. 4", "1.2.3.٤"] $ \text -> assertBool "IPv4 malformed text" (isLeft (Relay.ipv4FromText text))
  forM_ [":::1", "1::2::3", "0000:0000:0000:0000:0000:0000:0000:zzzz", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8::", "::ffff:256.1.2.3", "1.2.3.4::"] $ \text -> assertBool "IPv6 malformed text" (isLeft (Relay.ipv6FromText text))
  forM_ [("::", "0000:0000:0000:0000:0000:0000:0000:0000"), ("::1", "0000:0000:0000:0000:0000:0000:0000:0001"), ("1::", "0001:0000:0000:0000:0000:0000:0000:0000"), ("1:2:3:4:5:6:7:8", "0001:0002:0003:0004:0005:0006:0007:0008"), ("::FFFF:192.0.2.1", "0000:0000:0000:0000:0000:ffff:c000:0201"), ("1:2:3:4:5:6:192.0.2.1", "0001:0002:0003:0004:0005:0006:c000:0201")] $ \(input, expanded) -> do
    address <- expectRight (Relay.ipv6FromText input)
    Relay.ipv6Text address @?= expanded
  assertBool "empty DNS" (isLeft (Relay.mkDnsName ""))
  assertBool "NUL DNS" (isLeft (Relay.mkDnsName "a\0b"))
  assertBool "UTF8 DNS limit" (isLeft (Relay.mkDnsName (Text.replicate 33 "é")))
  dns <- expectRight (Relay.mkDnsName (Text.replicate 32 "é"))
  nativeAgreement 1 (Relay.encodeCbor (Relay.MultiHostName dns))
  _ <- expectRight (Metadata.mkUrl "")
  _ <- expectRight (Metadata.mkUrl (Text.replicate 64 "é"))
  assertBool "URL UTF8 limit" (isLeft (Metadata.mkUrl (Text.replicate 65 "é")))
  assertBool "NUL URL" (isLeft (Metadata.mkUrl "a\0b"))
  Bls.mkBlsKey ByteString.empty ByteString.empty @?= Left (InvalidPoolBlsKeyLength 0 0)
  assertBool "short proof" (isLeft (Bls.mkBlsKey (ByteString.replicate 96 0) (ByteString.replicate 47 0)))

checkInvalid :: IO ()
checkInvalid = do
  value <- expectRight sample
  forM_ [ByteString.empty, "\xff", ByteString.snoc (Pool.encodeCbor value) 0, ByteString.cons 0x88 (ByteString.drop 1 (Pool.encodeCbor value)), ByteString.init (Pool.encodeCbor value)] $ \bytes -> assertBool "pool invalid" (isLeft (Pool.decodeCbor bytes))
  forM_ ["820300", "84001a00010000f6f6", "84000043000000f6", "8301f660", "82026100", "820261ff", "9f02ff", "82020000"] $ \vector -> do
    bytes <- expectRight (hex vector)
    assertBool "relay malformed" (isLeft (Relay.decodeCbor bytes))
  forM_ ["80", "820040", "826000", "8260581f00000000000000000000000000000000000000000000000000000000000000"] $ \vector -> do
    bytes <- expectRight (hex vector)
    assertBool "metadata malformed" (isLeft (Metadata.decodeCbor bytes))
  assertBool "BLS malformed" (isLeft (Bls.decodeCbor "\x82\x40\x40"))
  let owner = Set.findMin (Pool.owners value)
      ownerBytes = Credential.keyHashBytes owner
      marker = ByteString.pack [0xd9, 1, 2, 0x81, 0x58, 0x1c] <> ownerBytes
      duplicate = ByteString.pack [0xd9, 1, 2, 0x82, 0x58, 0x1c] <> ownerBytes <> ByteString.pack [0x58, 0x1c] <> ownerBytes
      (prefix, suffix) = ByteString.breakSubstring marker (Pool.encodeCbor value)
  assertBool "duplicate owners rejected" (isLeft (Pool.decodeCbor (prefix <> duplicate <> ByteString.drop (ByteString.length marker) suffix)))

checkIndependence :: IO ()
checkIndependence = do
  original <- expectRight sample
  let changed = original {Pool.pledge = maxBound, Pool.cost = maxBound, Pool.relays = Pool.relays original ++ Pool.relays original, Pool.owners = Set.empty, Pool.metadata = Nothing}
  Pool.pledge original @?= 10000
  length (Pool.relays original) @?= 3
  Pool.decodeCbor (Pool.encodeCbor changed) @?= Right changed
  nativeAgreement 0 (Pool.encodeCbor changed)

checkRepeated :: IO ()
checkRepeated = do
  value <- expectRight sample
  bls <- expectRight sampleBls
  replicateM_ 100 (nativeAgreement 0 (Pool.encodeCbor value {Pool.blsKey = Just bls}))

propParameters :: Property
propParameters = property $ do
  keyBytes <- forAll (Gen.bytes (Range.singleton 28))
  vrfBytes <- forAll (Gen.bytes (Range.singleton 32))
  ipBytes <- forAll (Gen.bytes (Range.singleton 4))
  ip6Bytes <- forAll (Gen.bytes (Range.singleton 16))
  pledge <- forAll (Gen.word64 Range.constantBounded)
  cost <- forAll (Gen.word64 Range.constantBounded)
  numerator <- forAll (Gen.integral (Range.linear 0 1000))
  withBls <- forAll Gen.bool
  withMetadata <- forAll Gen.bool
  port <- forAll (Gen.maybe (Gen.word16 Range.constantBounded))
  base <- evalEither sample
  poolOperator <- evalEither (Credential.keyHashFromBytes keyBytes)
  owner <- evalEither (Credential.keyHashFromBytes keyBytes)
  vrf <- evalEither (Pool.vrfKeyHashFromBytes vrfBytes)
  proportion <- evalEither (Unit.mkUnitInterval numerator 1000)
  ipv4 <- evalEither (Relay.ipv4FromBytes ipBytes)
  ipv6 <- evalEither (Relay.ipv6FromBytes ip6Bytes)
  bls <- evalEither sampleBls
  let value = base {Pool.operator = poolOperator, Pool.vrfKeyHash = vrf, Pool.pledge = pledge, Pool.cost = cost, Pool.margin = proportion, Pool.blsKey = if withBls then Just bls else Nothing, Pool.metadata = if withMetadata then Pool.metadata base else Nothing, Pool.owners = Set.insert owner (Pool.owners base), Pool.relays = Relay.SingleHostAddress port (Just ipv4) (Just ipv6) : Pool.relays base}
  Pool.decodeCbor (Pool.encodeCbor value) === Right value
  evalIO (nativeAgreement 0 (Pool.encodeCbor value))

propIpText :: Property
propIpText = property $ do
  ipv4 <- evalEither . Relay.ipv4FromBytes =<< forAll (Gen.bytes (Range.singleton 4))
  ipv6 <- evalEither . Relay.ipv6FromBytes =<< forAll (Gen.bytes (Range.singleton 16))
  Relay.ipv4FromText (Relay.ipv4Text ipv4) === Right ipv4
  Relay.ipv6FromText (Relay.ipv6Text ipv6) === Right ipv6

nativeAgreement :: CUInt -> ByteString -> IO ()
nativeAgreement mode encoded = ByteString.useAsCStringLen encoded $ \(input, size) -> do
  agrees <- cAgreement mode (castPtr input) (fromIntegral size)
  agrees @?= 1

hex :: String -> Either Error ByteString
hex text = maybe (Left InvalidHex) Right (Hex.decodeHex (Text.pack text))

expectRight :: (Show failure) => Either failure value -> IO value
expectRight result = case result of
  Left failure -> assertFailure (show failure) >> fail "unreachable assertion"
  Right value -> pure value

-- Native vectors: cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/pool_params/{pool_params,pool_metadata,bls_key,relay}.cpp.
-- Copyright Biglup Labs, Apache-2.0. Groups below lack the public array framing.

nativeParameters :: String
nativeParameters = "581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef9258208dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db01927101903e8d81e820105581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810fd9010281581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8383011913886b6578616d706c652e636f6d8400191770447f000001f682026b6578616d706c652e636f6d827368747470733a2f2f6578616d706c652e636f6d58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"

nativeNoMetadata :: String
nativeNoMetadata = "581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef9258208dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db01927101903e8d81e820105581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810fd9010281581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8383011913886b6578616d706c652e636f6d8400191770447f000001f682026b6578616d706c652e636f6df6"

nativeWithBls :: String
nativeWithBls = "581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef9258208dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db0825860000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f5830606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f1927101903e8d81e820105581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810fd9010281581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8383011913886b6578616d706c652e636f6d8400191770447f000001f682026b6578616d706c652e636f6d827368747470733a2f2f6578616d706c652e636f6d58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"

nativeNullBls :: String
nativeNullBls = "581cd85087c646951407198c27b1b950fd2e99f28586c000ce39f6e6ef9258208dd154228946bd12967c12bedb1cb6038b78f8b84a1760b1a788fa72a4af3db0f61927101903e8d81e820105581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810fd9010281581ccb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f8383011913886b6578616d706c652e636f6d8400191770447f000001f682026b6578616d706c652e636f6d827368747470733a2f2f6578616d706c652e636f6d58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"

nativeMetadata :: String
nativeMetadata = "827368747470733a2f2f6578616d706c652e636f6d58200f3abbc8fc19c2e61bab6059bf8a466e6e754833a08a62a6c56fe0e78f19d9d5"

nativeBls :: String
nativeBls = "825860000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f5830606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f"

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_pool_agreement"
  cAgreement :: CUInt -> Ptr Word8 -> CSize -> IO CInt
