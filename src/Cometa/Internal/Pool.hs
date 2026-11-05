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
{-# LANGUAGE RankNTypes #-}

-- | Immutable pool values and schema workers. No native effects occur here.
module Cometa.Internal.Pool
  ( Ipv4,
    ipv4FromBytes,
    ipv4Bytes,
    ipv4FromText,
    ipv4Text,
    Ipv6,
    ipv6FromBytes,
    ipv6Bytes,
    ipv6FromText,
    ipv6Text,
    DnsName,
    mkDnsName,
    dnsNameText,
    Relay (..),
    Url,
    mkUrl,
    urlText,
    MetadataHash,
    metadataHashFromBytes,
    metadataHashBytes,
    Metadata (..),
    VrfKeyHash,
    vrfKeyHashFromBytes,
    vrfKeyHashBytes,
    BlsKey,
    mkBlsKey,
    publicKeyBytes,
    possessionProofBytes,
    PoolParameters (..),
    parametersFieldCount,
    relayEncoding,
    relayDecoder,
    metadataEncoding,
    metadataDecoder,
    blsEncoding,
    blsDecoder,
    parametersEncoding,
    parametersDecoder,
    parametersDecoderWithFieldCount,
    parametersValueEncoding,
    parametersValueDecoder,
    encode,
    decodeComplete,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.ProtocolValues as Protocol
import Control.Monad (replicateM, unless, when)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (isDigit, isHexDigit)
import Data.List (intercalate)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word16, Word64)
import Numeric (readHex, showHex)
import Text.Read (readMaybe)

-- TYPES ----------------------------------------------------------------------

-- | IPv4 address in network byte order. Equality and ordering compare bytes.
newtype Ipv4 = Ipv4 ByteString deriving (Eq, Ord, Show)

-- | IPv6 address in network byte order. Equality and ordering compare bytes.
newtype Ipv6 = Ipv6 ByteString deriving (Eq, Ord, Show)

-- | Relay DNS label, containing 1 through 64 UTF-8 bytes and no NUL.
-- DNS syntax and reachability are not checked. Comparison uses text.
newtype DnsName = DnsName Text deriving (Eq, Ord, Show)

-- | Relay alternatives. Ordering follows CBOR codes, then constructor fields.
-- Ports are unsigned 16-bit port numbers; absent fields encode as null.
data Relay
  = -- | IP relay: optional port, IPv4 and IPv6. All may be absent.
    SingleHostAddress !(Maybe Word16) !(Maybe Ipv4) !(Maybe Ipv6)
  | -- | A or AAAA DNS record, with optional port.
    SingleHostName !(Maybe Word16) !DnsName
  | -- | SRV DNS record; its port is supplied by DNS.
    MultiHostName !DnsName
  deriving (Eq, Ord, Show)

-- | Pool metadata location of 0 through 128 UTF-8 bytes with no NUL.
-- No URI syntax or reachability check is implied. Comparison uses text.
newtype Url = Url Text deriving (Eq, Ord, Show)

-- | Exact 32-byte BLAKE2b-256 metadata digest. Comparison uses bytes.
newtype MetadataHash = MetadataHash ByteString deriving (Eq, Ord, Show)

-- | Metadata reference. Fetching and checking the payload is a caller operation.
data Metadata = Metadata
  { -- | Off-chain location, including the native schema's empty location.
    url :: !Url,
    -- | Expected digest of exact payload bytes.
    metadataHash :: !MetadataHash
  }
  deriving (Eq, Ord, Show)

-- | Exact 32-byte VRF verification-key hash. Importing does not verify a key.
newtype VrfKeyHash = VrfKeyHash ByteString deriving (Eq, Ord, Show)

-- | BLS public key (96 bytes) and possession proof (48 bytes). Only lengths
-- are checked; construction does not verify group membership or proof validity.
-- Equality and ordering compare public-key bytes, then proof bytes.
data BlsKey = BlsKey !ByteString !ByteString deriving (Eq, Ord, Show)

-- | Registration parameters. Assembly and record updates are total because
-- constrained fields are validated values. Equality is semantic (numeric margin,
-- unordered owners, ordered relays); Show is diagnostic. No ledger-era admission,
-- minimum cost, pledge funding, or BLS proof verification is implied.
data PoolParameters = PoolParameters
  { -- | Pool operator verification-key hash, exactly 28 bytes.
    operator :: !(Credential.KeyHash Credential.StakePool),
    -- | VRF verification-key hash, exactly 32 bytes.
    vrfKeyHash :: !VrfKeyHash,
    -- | Optional Dijkstra BLS key and proof; absent in earlier registrations.
    blsKey :: !(Maybe BlsKey),
    -- | Pledged lovelace, from zero through 2^64 - 1.
    pledge :: !Word64,
    -- | Fixed pool cost in lovelace, from zero through 2^64 - 1.
    cost :: !Word64,
    -- | Exact share of remaining rewards, zero through one inclusive.
    margin :: !Protocol.UnitInterval,
    -- | Account receiving operator rewards, with its network tag preserved.
    rewardAccount :: !Reward.RewardAddress,
    -- | Staking key hashes. Set semantics remove repeated owners.
    owners :: !(Set (Credential.KeyHash Credential.Stake)),
    -- | Relay sequence; order and duplicates are preserved.
    relays :: ![Relay],
    -- | Optional off-chain metadata reference.
    metadata :: !(Maybe Metadata)
  }
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate an exact four-byte network-order IPv4 address.
-- Wrong lengths return 'InvalidPoolIpLength' with expected and actual lengths.
ipv4FromBytes :: ByteString -> Either Error Ipv4
ipv4FromBytes bytes = Ipv4 <$> exactIp 4 bytes

-- | Exact four-byte address.
ipv4Bytes :: Ipv4 -> ByteString
ipv4Bytes (Ipv4 bytes) = bytes

-- | Parse four decimal octets, each 0 through 255, separated by dots.
-- Leading zeros are accepted; signs, whitespace and empty octets are rejected.
-- Malformed input returns 'InvalidPoolIpText' with a diagnostic.
ipv4FromText :: Text -> Either Error Ipv4
ipv4FromText text = case traverse octet (Text.splitOn "." text) of
  Just values | length values == 4 -> ipv4FromBytes (ByteString.pack values)
  _ -> Left (InvalidPoolIpText "Invalid dotted IPv4 address")
  where
    octet part
      | Text.null part || Text.length part > 3 || not (Text.all isDigit part) = Nothing
      | otherwise = do
          value <- readMaybe (Text.unpack part) :: Maybe Int
          if value <= 255 then Just (fromIntegral value) else Nothing

-- | Canonical dotted decimal, without leading zeros.
ipv4Text :: Ipv4 -> Text
ipv4Text = Text.pack . intercalate "." . map show . ByteString.unpack . ipv4Bytes

-- | Validate an exact sixteen-byte network-order IPv6 address.
ipv6FromBytes :: ByteString -> Either Error Ipv6
ipv6FromBytes bytes = Ipv6 <$> exactIp 16 bytes

-- | Exact sixteen-byte address.
ipv6Bytes :: Ipv6 -> ByteString
ipv6Bytes (Ipv6 bytes) = bytes

-- | Parse IPv6 hexadecimal groups, accepting a single @::@ compression and
-- an optional final dotted IPv4 address. Hexadecimal letter case is ignored;
-- signs, whitespace, repeated compression and incorrect group counts return
-- 'InvalidPoolIpText'.
ipv6FromText :: Text -> Either Error Ipv6
ipv6FromText text = case expandIpv4Suffix text >>= ipv6Groups of
  Just groups -> ipv6FromBytes (ByteString.pack (concatMap networkBytes groups))
  Nothing -> Left (InvalidPoolIpText "Invalid IPv6 address")
  where
    networkBytes value = [fromIntegral (value `shiftR` 8), fromIntegral (value .&. 255)]

ipv6Groups :: Text -> Maybe [Word16]
ipv6Groups text = case Text.splitOn "::" text of
  [whole] -> do
    groups <- side whole
    if length groups == 8 then Just groups else Nothing
  [before, after] -> do
    left <- side before
    right <- side after
    let missing = 8 - length left - length right
    if missing > 0 then Just (left ++ replicate missing 0 ++ right) else Nothing
  _ -> Nothing
  where
    side part
      | Text.null part = Just []
      | otherwise = traverse group (Text.splitOn ":" part)
    group part
      | Text.null part || Text.length part > 4 || not (Text.all isHexDigit part) = Nothing
      | otherwise = case readHex (Text.unpack part) of
          [(value, "")] -> Just value
          _ -> Nothing

-- Convert a final dotted address into two hexadecimal groups before parsing
-- compression. Dotted input anywhere else remains invalid hexadecimal text.
expandIpv4Suffix :: Text -> Maybe Text
expandIpv4Suffix text
  | not (Text.any (== '.') text) = Just text
  | otherwise = do
      let (prefix, suffix) = Text.breakOnEnd ":" text
      when (Text.null prefix) Nothing
      address <- either (const Nothing) Just (ipv4FromText suffix)
      case ByteString.unpack (ipv4Bytes address) of
        [a, b, c, d] -> Just (prefix <> pair a b <> ":" <> pair c d)
        _ -> Nothing
  where
    pair a b = Text.pack (showHex (fromIntegral a * 256 + fromIntegral b :: Word16) "")

-- | Lowercase, fully expanded IPv6 text with eight four-digit groups.
ipv6Text :: Ipv6 -> Text
ipv6Text = Text.intercalate ":" . pairs . ByteString.unpack . ipv6Bytes
  where
    pairs (a : b : rest) = Text.pack (pad a ++ pad b) : pairs rest
    pairs _ = []
    pad value = let digits = showHex value "" in replicate (2 - length digits) '0' ++ digits

exactIp :: Int -> ByteString -> Either Error ByteString
exactIp size bytes
  | ByteString.length bytes == size = Right bytes
  | otherwise = Left (InvalidPoolIpLength size (ByteString.length bytes))

-- | Validate 1 through 64 UTF-8 bytes and reject NUL, returning
-- 'InvalidPoolDnsName' on either violation. DNS syntax is not checked.
mkDnsName :: Text -> Either Error DnsName
mkDnsName text
  | size < 1 || size > 64 || Text.any (== '\0') text = Left (InvalidPoolDnsName "Expected 1 through 64 UTF-8 bytes without NUL")
  | otherwise = Right (DnsName text)
  where
    size = ByteString.length (Text.encodeUtf8 text)

-- | Original DNS text.
dnsNameText :: DnsName -> Text
dnsNameText (DnsName text) = text

-- | Validate at most 128 UTF-8 bytes without NUL. Empty is valid in this
-- pool schema. Violations return 'InvalidPoolMetadataUrl'.
mkUrl :: Text -> Either Error Url
mkUrl text
  | ByteString.length (Text.encodeUtf8 text) > 128 || Text.any (== '\0') text = Left (InvalidPoolMetadataUrl "Expected at most 128 UTF-8 bytes without NUL")
  | otherwise = Right (Url text)

-- | Exact original location text.
urlText :: Url -> Text
urlText (Url text) = text

-- | Import exactly 32 metadata digest bytes without hashing; other lengths
-- return 'InvalidPoolMetadataHashLength' with the actual byte count.
metadataHashFromBytes :: ByteString -> Either Error MetadataHash
metadataHashFromBytes bytes
  | ByteString.length bytes == 32 = Right (MetadataHash bytes)
  | otherwise = Left (InvalidPoolMetadataHashLength (ByteString.length bytes))

-- | Exact metadata digest bytes.
metadataHashBytes :: MetadataHash -> ByteString
metadataHashBytes (MetadataHash bytes) = bytes

-- | Import exactly 32 VRF digest bytes without hashing; other lengths return
-- 'InvalidPoolHashLength' with the actual byte count.
vrfKeyHashFromBytes :: ByteString -> Either Error VrfKeyHash
vrfKeyHashFromBytes bytes
  | ByteString.length bytes == 32 = Right (VrfKeyHash bytes)
  | otherwise = Left (InvalidPoolHashLength (ByteString.length bytes))

-- | Exact VRF digest bytes.
vrfKeyHashBytes :: VrfKeyHash -> ByteString
vrfKeyHashBytes (VrfKeyHash bytes) = bytes

-- | Validate public-key bytes (first argument, 96 bytes) and possession-proof
-- bytes (second argument, 48 bytes). 'InvalidPoolBlsKeyLength' reports both
-- actual lengths. No cryptographic validation occurs.
mkBlsKey :: ByteString -> ByteString -> Either Error BlsKey
mkBlsKey key proof
  | ByteString.length key == 96 && ByteString.length proof == 48 = Right (BlsKey key proof)
  | otherwise = Left (InvalidPoolBlsKeyLength (ByteString.length key) (ByteString.length proof))

-- | Exact 96 public-key bytes.
publicKeyBytes :: BlsKey -> ByteString
publicKeyBytes (BlsKey key _) = key

-- | Exact 48 possession-proof bytes.
possessionProofBytes :: BlsKey -> ByteString
possessionProofBytes (BlsKey _ proof) = proof

encode :: (a -> Encode.Encoding) -> a -> ByteString
encode encoder = Write.toStrictByteString . encoder

decodeComplete :: (forall s. Decode.Decoder s a) -> ByteString -> Either Error a
decodeComplete decoder bytes = case Read.deserialiseFromBytes decoder (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidPoolCbor (Text.pack (show failure)))
  Right (remaining, value)
    | Lazy.null remaining -> Right value
    | otherwise -> Left (InvalidPoolCbor "Trailing pool CBOR bytes")

metadataEncoding :: Metadata -> Encode.Encoding
metadataEncoding (Metadata location digest) = Encode.encodeListLen 2 <> Encode.encodeString (urlText location) <> Encode.encodeBytes (metadataHashBytes digest)

metadataDecoder :: Decode.Decoder s Metadata
metadataDecoder = arrayOf 2 $ Metadata <$> (validated mkUrl =<< Decode.decodeString) <*> (validated metadataHashFromBytes =<< Decode.decodeBytes)

blsEncoding :: BlsKey -> Encode.Encoding
blsEncoding (BlsKey key proof) = Encode.encodeListLen 2 <> Encode.encodeBytes key <> Encode.encodeBytes proof

blsDecoder :: Decode.Decoder s BlsKey
blsDecoder = arrayOf 2 $ do
  key <- Decode.decodeBytes
  proof <- Decode.decodeBytes
  validated (uncurry mkBlsKey) (key, proof)

relayEncoding :: Relay -> Encode.Encoding
relayEncoding relay = case relay of
  SingleHostAddress port ipv4 ipv6 -> Encode.encodeListLen 4 <> Encode.encodeWord 0 <> optional Encode.encodeWord16 port <> optional (Encode.encodeBytes . ipv4Bytes) ipv4 <> optional (Encode.encodeBytes . ipv6Bytes) ipv6
  SingleHostName port dns -> Encode.encodeListLen 3 <> Encode.encodeWord 1 <> optional Encode.encodeWord16 port <> Encode.encodeString (dnsNameText dns)
  MultiHostName dns -> Encode.encodeListLen 2 <> Encode.encodeWord 2 <> Encode.encodeString (dnsNameText dns)

relayDecoder :: Decode.Decoder s Relay
relayDecoder = do
  size <- Decode.decodeListLenOrIndef
  kind <- Decode.decodeWord
  expected <- case kind of
    0 -> pure 4
    1 -> pure 3
    2 -> pure 2
    _ -> fail "Unknown relay kind"
  checkSize expected size
  value <- case kind of
    0 -> SingleHostAddress <$> nullable Decode.decodeWord16 <*> nullable (validated ipv4FromBytes =<< Decode.decodeBytes) <*> nullable (validated ipv6FromBytes =<< Decode.decodeBytes)
    1 -> SingleHostName <$> nullable Decode.decodeWord16 <*> (validated mkDnsName =<< Decode.decodeString)
    _ -> MultiHostName <$> (validated mkDnsName =<< Decode.decodeString)
  endArray size
  pure value

parametersFieldCount :: PoolParameters -> Word
parametersFieldCount value = maybe 9 (const 10) (blsKey value)

parametersEncoding :: PoolParameters -> Encode.Encoding
parametersEncoding value =
  Encode.encodeBytes (Credential.keyHashBytes (operator value))
    <> Encode.encodeBytes (vrfKeyHashBytes (vrfKeyHash value))
    <> foldMap blsEncoding (blsKey value)
    <> Encode.encodeWord64 (pledge value)
    <> Encode.encodeWord64 (cost value)
    <> Protocol.encodeUnitInterval (margin value)
    <> Encode.encodeBytes (Reward.toBytes (rewardAccount value))
    <> Encode.encodeTag 258
    <> Encode.encodeListLen (fromIntegral (Set.size (owners value)))
    <> foldMap (Encode.encodeBytes . Credential.keyHashBytes) (Set.toAscList (owners value))
    <> Encode.encodeListLen (fromIntegral (length (relays value)))
    <> foldMap relayEncoding (relays value)
    <> optional metadataEncoding (metadata value)

parametersDecoder :: Decode.Decoder s PoolParameters
parametersDecoder = snd <$> parametersDecoderWithFieldCount

parametersDecoderWithFieldCount :: Decode.Decoder s (Word, PoolParameters)
parametersDecoderWithFieldCount = do
  poolOperator <- validated Credential.keyHashFromBytes =<< Decode.decodeBytes
  vrf <- validated vrfKeyHashFromBytes =<< Decode.decodeBytes
  token <- Decode.peekTokenType
  bls <- case token of
    Decode.TypeListLen -> Just <$> blsDecoder
    Decode.TypeListLenIndef -> Just <$> blsDecoder
    Decode.TypeNull -> Decode.decodeNull >> pure Nothing
    _ -> pure Nothing
  poolPledge <- Decode.decodeWord64
  poolCost <- Decode.decodeWord64
  poolMargin <- Protocol.decodeUnitInterval
  account <- validated Reward.fromBytes =<< Decode.decodeBytes
  ownerSet <- ownersDecoder
  relayList <- listOf relayDecoder
  reference <- nullable metadataDecoder
  let count = case token of
        Decode.TypeListLen -> 10
        Decode.TypeListLenIndef -> 10
        Decode.TypeNull -> 10
        _ -> 9
  pure (count, PoolParameters poolOperator vrf bls poolPledge poolCost poolMargin account ownerSet relayList reference)

parametersValueEncoding :: PoolParameters -> Encode.Encoding
parametersValueEncoding value = Encode.encodeListLen (fromIntegral (parametersFieldCount value)) <> parametersEncoding value

parametersValueDecoder :: Decode.Decoder s PoolParameters
parametersValueDecoder = do
  size <- Decode.decodeListLenOrIndef
  (count, value) <- parametersDecoderWithFieldCount
  checkSize (fromIntegral count) size
  endArray size
  pure value

ownersDecoder :: Decode.Decoder s (Set (Credential.KeyHash Credential.Stake))
ownersDecoder = do
  token <- Decode.peekTokenType
  when (token == Decode.TypeTag) $ do
    tag <- Decode.decodeTag
    unless (tag == 258) (fail "Incorrect pool-owner set tag")
  values <- listOf (validated Credential.keyHashFromBytes =<< Decode.decodeBytes)
  let unique = Set.fromList values
  unless (Set.size unique == length values) (fail "Duplicate pool owner")
  pure unique

optional :: (a -> Encode.Encoding) -> Maybe a -> Encode.Encoding
optional = maybe Encode.encodeNull

nullable :: Decode.Decoder s a -> Decode.Decoder s (Maybe a)
nullable decoder = do
  token <- Decode.peekTokenType
  if token == Decode.TypeNull then Decode.decodeNull >> pure Nothing else Just <$> decoder

listOf :: Decode.Decoder s a -> Decode.Decoder s [a]
listOf decoder = do
  size <- Decode.decodeListLenOrIndef
  case size of
    Just count -> replicateM count decoder
    Nothing -> go
  where
    go = do
      ended <- Decode.decodeBreakOr
      if ended then pure [] else (:) <$> decoder <*> go

arrayOf :: Int -> Decode.Decoder s a -> Decode.Decoder s a
arrayOf expected decoder = do
  size <- Decode.decodeListLenOrIndef
  checkSize expected size
  value <- decoder
  endArray size
  pure value

checkSize :: Int -> Maybe Int -> Decode.Decoder s ()
checkSize expected size = case size of
  Just actual -> unless (actual == expected) (fail "Incorrect pool array length")
  Nothing -> pure ()

endArray :: Maybe Int -> Decode.Decoder s ()
endArray size = case size of
  Just _ -> pure ()
  Nothing -> do
    ended <- Decode.decodeBreakOr
    unless ended (fail "Extra pool array elements")

validated :: (a -> Either Error b) -> a -> Decode.Decoder s b
validated validate value = either (fail . show) pure (validate value)
