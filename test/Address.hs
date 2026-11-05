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

module Address (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.Binary.Bech32 as Bech32
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import Cometa.Credential (Credential (..))
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import Cometa.Error (Error (..))
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (evaluate)
import Control.Monad (forM_, replicateM_)
import Data.Bits (shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import qualified Fixtures.Address as Fixtures
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalEither, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- TYPES ----------------------------------------------------------------------

-- Test-only sum permits shared vector/property loops without erasing the public
-- distinction between transaction destinations and reward accounts.
data TestAddress = PaymentAddress Shelley.Address | RewardAccount Reward.RewardAddress
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Shelley addresses"
    [ testCase "network and hash validation bounds" checkBounds,
      testCase "CIP-19 all supported forms on mainnet and testnet" checkVectors,
      testCase "all network tags agree with native credential construction" checkNative,
      testCase "exact lengths and unsupported headers" checkBytes,
      testCase "payment addresses and reward accounts have disjoint decoders" checkFamilies,
      testCase "Bech32 casing checksum and lexical rejection" checkText,
      testCase "valid checksums cannot disguise header or trailing payload" checkStrictText,
      testCase "fixed prefixes and strict bit padding" checkPadding,
      testCase "public key credential hashes agree and survive cleanup" checkPublicKey,
      testCase "owned values survive GC and failures" checkLifetime,
      testCase "pure codec shared evaluation is deterministic" checkDeterminism,
      testProperty "owned construction and byte/text roundtrips" propRoundTrip
    ]

checkBounds :: IO ()
checkBounds = do
  forM_ [-2, -1, 16, 18446744073709551616] $ \value -> Shelley.mkNetworkId value @?= Left (InvalidNetworkId value)
  Shelley.mkNetworkId 0 @?= Right (minBound :: Shelley.NetworkId)
  Shelley.mkNetworkId 15 @?= Right (maxBound :: Shelley.NetworkId)
  forM_ [0, 1, 27, 29, 57] $ \size -> do
    let bytes = ByteString.replicate size 0
    (Credential.keyHashFromBytes bytes :: Either Error (Credential.KeyHash Credential.Payment)) @?= Left (InvalidCredentialHashLength size)
    Credential.scriptHashFromBytes bytes @?= Left (InvalidCredentialHashLength size)

checkVectors :: IO ()
checkVectors = forM_ Fixtures.vectors $ \(network, tag, text) -> do
  address <- fixture network tag
  toText address @?= text
  fromText text @?= Right address
  fromText (Text.toUpper text) @?= Right address
  fromBytes (toBytes address) @?= Right address
  fmap credentialBytes (paymentCredential address) @?= expectedPayment tag
  fmap credentialBytes (stakeCredential address) @?= expectedStake tag

checkNative :: IO ()
checkNative = forM_ [0 .. 15] $ \network -> forM_ [0, 1, 2, 3, 6, 7, 14, 15] $ \tag -> do
  address <- fixture network tag
  -- Oracle reconstructs native credentials and an address from separate fields.
  withBytes (toBytes address) $ \input size ->
    withBytes (Text.encodeUtf8 (toText address)) $ \text textSize ->
      cNativeAgreement input size text textSize >>= (@?= 1)
  let encoded = toText address
  let prefix = (if tag >= 14 then "stake" else "addr") <> (if network == 1 then "1" else "_test1")
  Text.isPrefixOf prefix encoded @?= True
  fromText encoded @?= Right address

checkBytes :: IO ()
checkBytes = do
  fromBytes ByteString.empty @?= Left InvalidShelleyAddress
  forM_ [0, 1, 2, 3, 6, 7, 14, 15] $ \tag -> do
    address <- fixture 1 tag
    let bytes = toBytes address
    fromBytes (ByteString.take (ByteString.length bytes - 1) bytes) @?= Left InvalidShelleyAddress
    fromBytes (bytes <> "\NUL") @?= Left InvalidShelleyAddress
  forM_ [4, 5, 8, 9, 10, 11, 12, 13] $ \tag ->
    fromBytes (ByteString.singleton (tag `shiftL` 4) <> ByteString.replicate 56 0) @?= Left (UnsupportedAddressType tag)

checkText :: IO ()
checkText = do
  address <- fixture 1 0
  let text = toText address
  forM_ ["", " " <> text, text <> "\NUL", text <> "\n", "中文", Text.replicate 121 "x", "A" <> Text.drop 1 text] $ \bad ->
    do
      let result = fromText bad
      result @?= Left InvalidShelleyAddressText
  let corrupted = Text.dropEnd 1 text <> "q"
      result = fromText corrupted
  case result of
    Left InvalidShelleyAddressText -> pure ()
    _ -> assertFailure ("Expected checksum failure, got " <> show result)

checkStrictText :: IO ()
checkStrictText = do
  address <- fixture 1 0
  forM_ ["stake", "addr_test", "addr_extra"] $ \hrp -> do
    text <- customText hrp (toBytes address)
    fromText text @?= Left InvalidShelleyAddressText
  text <- customText "addr" (toBytes address <> "\NUL")
  fromText text @?= Left InvalidShelleyAddress
  testAddress <- fixture 0 6
  wrongNetwork <- customText "addr" (toBytes testAddress)
  fromText wrongNetwork @?= Left InvalidShelleyAddressText
  pointer <- customText "addr" (ByteString.singleton 0x41 <> ByteString.replicate 28 0 <> ByteString.pack [0, 0, 0])
  fromText pointer @?= Left (UnsupportedAddressType 4)

checkPublicKey :: IO ()
checkPublicKey = do
  key <- requireRight (PublicKey.fromBytes (ByteString.replicate 32 7))
  payment <- Credential.fromPublicKey key >>= requireRight
  stake <- Credential.fromPublicKey key >>= requireRight
  digest <- PublicKey.hash key >>= requireRight
  performGC
  let address = PaymentAddress (Shelley.base Shelley.testnet payment stake)
  fmap credentialBytes (paymentCredential address) @?= Just (Blake2b.toBytes digest)
  fmap credentialBytes (stakeCredential address) @?= Just (Blake2b.toBytes digest)

checkLifetime :: IO ()
checkLifetime = do
  original <- fixture 1 3
  let text = toText original
  copied <- requireRight (fromText text)
  replicateM_ 100 $ do
    fromText "bad1address" @?= Left InvalidShelleyAddressText
    toText copied @?= text
  performGC
  copied @?= original
  fromBytes (toBytes copied) @?= Right original

checkDeterminism :: IO ()
checkDeterminism = do
  address <- fixture 1 0
  let shared = toText address
  done <- newEmptyMVar
  replicateM_ 4 $ forkFinally (evaluate shared) (putMVar done)
  replicateM_ 4 $ do
    result <- takeMVar done
    case result of
      Left exception -> assertFailure (show exception)
      Right encoded -> encoded @?= toText address
  performGC
  let encoded = shared
  fromText encoded @?= Right address

propRoundTrip :: Property
propRoundTrip = property $ do
  network <- forAll (Gen.integral (Range.linear 0 15)) >>= evalEither . Shelley.mkNetworkId
  tag <- forAll (Gen.element [0, 1, 2, 3, 6, 7, 14, 15])
  payment <- forAll (Gen.bytes (Range.singleton 28))
  stake <- forAll (Gen.bytes (Range.singleton 28))
  address <- evalEither (assemble network tag payment stake)
  fromBytes (toBytes address) === Right address
  let encoded = toText address
  decoded <- evalEither (fromText encoded)
  decoded === address

fixture :: Integer -> Int -> IO TestAddress
fixture network tag = do
  networkTag <- requireRight (Shelley.mkNetworkId network)
  payment <- hex "9493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e"
  stake <- hex "337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251"
  script <- hex "c37b1b5dc0669f1d3c61a6fddb2e8fde96be87b881c60bce8e8d542f"
  requireRight (assemble networkTag tag (if odd tag then script else payment) (if tag `elem` [2, 3, 15] then script else stake))

assemble :: Shelley.NetworkId -> Int -> ByteString -> ByteString -> Either Error TestAddress
assemble network tag payment stake = case tag of
  value | value <= 3 -> PaymentAddress <$> (Shelley.base network <$> credential (odd tag) payment <*> credential (tag >= 2) stake)
  value | value == 6 || value == 7 -> PaymentAddress . Shelley.enterprise network <$> credential (odd tag) payment
  value | value == 14 || value == 15 -> RewardAccount . Reward.fromCredential network <$> credential (odd tag) stake
  _ -> Left InvalidShelleyAddress
  where
    credential script bytes
      | script = ScriptCredential <$> Credential.scriptHashFromBytes bytes
      | otherwise = KeyCredential <$> Credential.keyHashFromBytes bytes

expectedPayment :: Int -> Maybe ByteString
expectedPayment tag
  | tag >= 14 = Nothing
  | odd tag = Just scriptBytes
  | otherwise = Just paymentBytes

expectedStake :: Int -> Maybe ByteString
expectedStake tag
  | tag == 6 || tag == 7 = Nothing
  | tag `elem` [2, 3, 15] = Just scriptBytes
  | otherwise = Just stakeBytes

-- Exact credential bytes from the native CIP-19 fixture.
paymentBytes, stakeBytes, scriptBytes :: ByteString
paymentBytes = ByteString.pack [0x94, 0x93, 0x31, 0x5c, 0xd9, 0x2e, 0xb5, 0xd8, 0xc4, 0x30, 0x4e, 0x67, 0xb7, 0xe1, 0x6a, 0xe3, 0x6d, 0x61, 0xd3, 0x45, 0x02, 0x69, 0x46, 0x57, 0x81, 0x1a, 0x2c, 0x8e]
stakeBytes = ByteString.pack [0x33, 0x7b, 0x62, 0xcf, 0xff, 0x64, 0x03, 0xa0, 0x6a, 0x3a, 0xcb, 0xc3, 0x4f, 0x8c, 0x46, 0x00, 0x3c, 0x69, 0xfe, 0x79, 0xa3, 0x62, 0x8c, 0xef, 0xa9, 0xc4, 0x72, 0x51]
scriptBytes = ByteString.pack [0xc3, 0x7b, 0x1b, 0x5d, 0xc0, 0x66, 0x9f, 0x1d, 0x3c, 0x61, 0xa6, 0xfd, 0xdb, 0x2e, 0x8f, 0xde, 0x96, 0xbe, 0x87, 0xb8, 0x81, 0xc6, 0x0b, 0xce, 0x8e, 0x8d, 0x54, 0x2f]

credentialBytes :: Credential purpose -> ByteString
credentialBytes credential = case credential of
  KeyCredential hash -> Credential.keyHashBytes hash
  ScriptCredential hash -> Credential.scriptHashBytes hash

hex :: Text.Text -> IO ByteString
hex = fmap Blake2b.toBytes . requireRight . Blake2b.fromHex

requireRight :: (Show err) => Either err value -> IO value
requireRight = either (fail . show) pure

withBytes :: ByteString -> (Ptr Word8 -> CSize -> IO value) -> IO value
withBytes bytes action = ByteString.useAsCStringLen bytes $ \(pointer, size) -> action (castPtr pointer) (fromIntegral size)

customText :: ByteString -> ByteString -> IO Text.Text
customText hrp bytes = ByteString.useAsCString hrp $ \prefix -> withBytes bytes $ \input size ->
  allocaBytes 160 $ \output -> do
    cBech32 prefix input size output 160 >>= (@?= 0)
    Text.decodeUtf8 <$> ByteString.packCString (castPtr output)

toBytes :: TestAddress -> ByteString
toBytes address = case address of
  PaymentAddress value -> Shelley.toBytes value
  RewardAccount value -> Reward.toBytes value

fromBytes :: ByteString -> Either Error TestAddress
fromBytes bytes = case Shelley.fromBytes bytes of
  Left (UnsupportedAddressType tag) | tag == 14 || tag == 15 -> RewardAccount <$> Reward.fromBytes bytes
  result -> PaymentAddress <$> result

toText :: TestAddress -> Text.Text
toText address = case address of
  PaymentAddress value -> Shelley.toText value
  RewardAccount value -> Reward.toText value

fromText :: Text.Text -> Either Error TestAddress
fromText text = case Shelley.fromText text of
  Left (UnsupportedAddressType tag) | tag == 14 || tag == 15 -> RewardAccount <$> Reward.fromText text
  result -> PaymentAddress <$> result

paymentCredential :: TestAddress -> Maybe (Credential Credential.Payment)
paymentCredential address = case address of
  PaymentAddress value -> Just (Shelley.paymentCredential value)
  RewardAccount _ -> Nothing

stakeCredential :: TestAddress -> Maybe (Credential Credential.Stake)
stakeCredential address = case address of
  PaymentAddress value -> Shelley.stakeCredential value
  RewardAccount value -> Just (Reward.credential value)

checkFamilies :: IO ()
checkFamilies = do
  forM_ [0, 1, 2, 3, 6, 7] $ \tag -> do
    address <- fixture 1 tag
    Reward.fromBytes (toBytes address) @?= Left (UnsupportedAddressType (fromIntegral tag))
    let text = toText address
    Reward.fromText text @?= Left (UnsupportedAddressType (fromIntegral tag))
  forM_ [14, 15] $ \tag -> do
    address <- fixture 1 tag
    Shelley.fromBytes (toBytes address) @?= Left (UnsupportedAddressType (fromIntegral tag))
    let text = toText address
    Shelley.fromText text @?= Left (UnsupportedAddressType (fromIntegral tag))

checkPadding :: IO ()
checkPadding = do
  forM_ ["addr", "addr_test", "stake", "stake_test"] $ \prefix ->
    fmap Bech32.humanReadablePartToText (Bech32.humanReadablePartFromText prefix) @?= Right prefix
  address <- fixture 1 6
  prefix <- requireRight (Bech32.humanReadablePartFromText "addr")
  let words5 = Bech32.dataPartToWords (Bech32.dataPartFromBytes (toBytes address))
      excessive = Bech32.encodeLenient prefix (Bech32.dataPartFromWords (words5 <> [minBound, minBound]))
  fromText excessive @?= Left InvalidShelleyAddressText
  case reverse words5 of
    [] -> assertFailure "Fixture did not produce data words"
    _ : rest -> do
      let nonzero = Bech32.encodeLenient prefix (Bech32.dataPartFromWords (reverse (maxBound : rest)))
      fromText nonzero @?= Left InvalidShelleyAddressText
  fromText (Bech32.encodeLenient prefix (Bech32.dataPartFromBytes ByteString.empty)) @?= Left InvalidShelleyAddress

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_address_agreement"
  cNativeAgreement :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall safe "cometa_test_address_bech32"
  cBech32 :: Ptr a -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CUInt
