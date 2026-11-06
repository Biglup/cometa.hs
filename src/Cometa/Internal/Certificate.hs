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

-- | Immutable certificates, exact envelopes and private CBOR schema workers.
-- No native resources or effects are used by these codecs.
module Cometa.Internal.Certificate
  ( Certificate (..),
    Mir (..),
    Pot (..),
    EncodedCertificate,
    encodeCertificate,
    decodeCertificate,
    fromCertificate,
    toCertificate,
    certificateCbor,
    Certificates (..),
    EncodedCertificates,
    encodeCertificates,
    decodeCertificates,
    fromCertificates,
    toCertificates,
    certificatesCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Term as Term
import qualified Codec.CBOR.Write as Write
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Internal.Pool as Pool
import Control.Monad (foldM, replicateM, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Source accounting pot for instantaneous rewards. Ordering follows CBOR codes.
data Pot
  = -- | The reserve accounting pot.
    Reserves
  | -- | The treasury accounting pot.
    Treasury
  deriving (Eq, Ord, Show, Bounded, Enum)

-- | Instantaneous reward transfers. All quantities are
-- lovelace from 0 through 2^64-1; signed reward adjustments are rejected.
data Mir
  = -- | Transfer from the source pot to the other accounting pot.
    ToOtherPot !Pot !Word64
  | -- | Assign rewards from the source pot to unique stake credentials.
    ToStakeCredentials !Pot !(Map (Credential.Credential Credential.Stake) Word64)
  deriving (Eq, Ord, Show)

-- | Certificate semantic data. Deposits, refunds and reward amounts are unsigned
-- 64-bit lovelace. Constructors do not check protocol parameters, era eligibility,
-- registration state, witnesses, or ledger acceptance. Equality and ordering
-- compare constructor then fields; 'Show' is diagnostic.
data Certificate
  = -- | Register a stake credential without an explicit deposit (legacy form).
    StakeRegistration !(Credential.Credential Credential.Stake)
  | -- | Deregister a stake credential without an explicit refund (legacy form).
    StakeDeregistration !(Credential.Credential Credential.Stake)
  | -- | Delegate stake to the pool identified by its operator key hash.
    StakeDelegation !(Credential.Credential Credential.Stake) !(Credential.KeyHash Credential.StakePool)
  | -- | Register or update all pool parameters.
    PoolRegistration !Pool.PoolParameters
  | -- | Retire a pool at the given epoch (unsigned 64-bit epoch number).
    PoolRetirement !(Credential.KeyHash Credential.StakePool) !Word64
  | -- | Delegate a genesis key to a delegate key and VRF key hash (legacy form).
    GenesisKeyDelegation !(Credential.KeyHash Credential.Genesis) !(Credential.KeyHash Credential.GenesisDelegate) !Pool.VrfKeyHash
  | -- | Transfer instantaneous rewards (legacy form).
    MoveInstantaneousRewards !Mir
  | -- | Register a stake credential with its explicit deposit in lovelace.
    Registration !(Credential.Credential Credential.Stake) !Word64
  | -- | Deregister a stake credential with its explicit refund in lovelace.
    Unregistration !(Credential.Credential Credential.Stake) !Word64
  | -- | Delegate voting power to a DRep or a predefined target.
    VoteDelegation !(Credential.Credential Credential.Stake) !DRep.DRep
  | -- | Delegate stake and voting power together.
    StakeVoteDelegation !(Credential.Credential Credential.Stake) !(Credential.KeyHash Credential.StakePool) !DRep.DRep
  | -- | Register and delegate stake; the last argument is the deposit in lovelace.
    StakeRegistrationDelegation !(Credential.Credential Credential.Stake) !(Credential.KeyHash Credential.StakePool) !Word64
  | -- | Register and delegate voting power; the last argument is the deposit in lovelace.
    VoteRegistrationDelegation !(Credential.Credential Credential.Stake) !DRep.DRep !Word64
  | -- | Register and delegate both powers; the last argument is the deposit in lovelace.
    StakeVoteRegistrationDelegation !(Credential.Credential Credential.Stake) !(Credential.KeyHash Credential.StakePool) !DRep.DRep !Word64
  | -- | Authorize a committee hot credential using its cold credential.
    AuthorizeCommitteeHot !(Credential.Credential Credential.CommitteeCold) !(Credential.Credential Credential.CommitteeHot)
  | -- | Resign a committee cold credential with an optional explanation.
    ResignCommitteeCold !(Credential.Credential Credential.CommitteeCold) !(Maybe Anchor.Anchor)
  | -- | Register a DRep with its deposit in lovelace and optional metadata.
    RegisterDRep !(Credential.Credential Credential.DRep) !Word64 !(Maybe Anchor.Anchor)
  | -- | Unregister a DRep with its refund in lovelace.
    UnregisterDRep !(Credential.Credential Credential.DRep) !Word64
  | -- | Update or remove a DRep metadata anchor.
    UpdateDRep !(Credential.Credential Credential.DRep) !(Maybe Anchor.Anchor)
  deriving (Eq, Ord, Show)

-- | Certificate with its exact original CBOR. Equality and ordering include bytes.
data EncodedCertificate = EncodedCertificate !ByteString !Certificate deriving (Eq, Ord, Show)

-- | Ordered certificates. Order and repeated certificates are preserved, matching
-- the native certificate collection despite its historical set name.
newtype Certificates = Certificates [Certificate] deriving (Eq, Ord, Show)

-- | Ordered certificates retaining their complete imported CBOR envelope.
data EncodedCertificates = EncodedCertificates !ByteString !Certificates deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite certificate encoding, with canonical unsigned integers.
encodeCertificate :: Certificate -> ByteString
encodeCertificate = Write.toStrictByteString . certificateEncoding

-- | Validate a complete certificate and retain exact bytes; schema failures return InvalidCertificateCbor.
decodeCertificate :: ByteString -> Either Error EncodedCertificate
decodeCertificate bytes = EncodedCertificate bytes <$> decodeComplete certificateDecoder bytes

-- | Create an exact envelope using fresh certificate encoding.
fromCertificate :: Certificate -> EncodedCertificate
fromCertificate value = EncodedCertificate (encodeCertificate value) value

-- | Inspect semantic certificate fields without changing the exact envelope.
toCertificate :: EncodedCertificate -> Certificate
toCertificate (EncodedCertificate _ value) = value

-- | Return original bytes for an imported certificate envelope.
certificateCbor :: EncodedCertificate -> ByteString
certificateCbor (EncodedCertificate bytes _) = bytes

-- | Encode ordered entries with set tag 258, retaining repeated certificates.
encodeCertificates :: Certificates -> ByteString
encodeCertificates (Certificates values) = Write.toStrictByteString (Encode.encodeTag 258 <> Encode.encodeListLen (fromIntegral (length values)) <> foldMap certificateEncoding values)

-- | Validate an optionally tagged collection and retain its complete bytes.
decodeCertificates :: ByteString -> Either Error EncodedCertificates
decodeCertificates bytes = EncodedCertificates bytes <$> decodeComplete certificatesDecoder bytes

-- | Wrap an ordered collection using its fresh definite encoding.
fromCertificates :: Certificates -> EncodedCertificates
fromCertificates value = EncodedCertificates (encodeCertificates value) value

-- | Inspect the ordered semantic collection.
toCertificates :: EncodedCertificates -> Certificates
toCertificates (EncodedCertificates _ value) = value

-- | Return the exact imported collection bytes.
certificatesCbor :: EncodedCertificates -> ByteString
certificatesCbor (EncodedCertificates bytes _) = bytes

certificateEncoding :: Certificate -> Encode.Encoding
certificateEncoding certificate = case certificate of
  StakeRegistration stake -> Encode.encodeListLen 2 <> Encode.encodeWord 0 <> credentialEncoding stake
  StakeDeregistration stake -> Encode.encodeListLen 2 <> Encode.encodeWord 1 <> credentialEncoding stake
  StakeDelegation stake pool -> Encode.encodeListLen 3 <> Encode.encodeWord 2 <> credentialEncoding stake <> keyEncoding pool
  PoolRegistration parameters -> Encode.encodeListLen (1 + Pool.parametersFieldCount parameters) <> Encode.encodeWord 3 <> Pool.parametersEncoding parameters
  PoolRetirement pool epoch -> Encode.encodeListLen 3 <> Encode.encodeWord 4 <> keyEncoding pool <> Encode.encodeWord64 epoch
  GenesisKeyDelegation genesis delegate vrf -> Encode.encodeListLen 4 <> Encode.encodeWord 5 <> keyEncoding genesis <> keyEncoding delegate <> (Encode.encodeBytes . Pool.vrfKeyHashBytes) vrf
  MoveInstantaneousRewards rewards -> Encode.encodeListLen 2 <> Encode.encodeWord 6 <> mirEncoding rewards
  Registration stake deposit -> Encode.encodeListLen 3 <> Encode.encodeWord 7 <> credentialEncoding stake <> Encode.encodeWord64 deposit
  Unregistration stake refund -> Encode.encodeListLen 3 <> Encode.encodeWord 8 <> credentialEncoding stake <> Encode.encodeWord64 refund
  VoteDelegation stake drep -> Encode.encodeListLen 3 <> Encode.encodeWord 9 <> credentialEncoding stake <> (Encode.encodePreEncoded . DRep.encodeCbor) drep
  StakeVoteDelegation stake pool drep -> Encode.encodeListLen 4 <> Encode.encodeWord 10 <> credentialEncoding stake <> keyEncoding pool <> (Encode.encodePreEncoded . DRep.encodeCbor) drep
  StakeRegistrationDelegation stake pool deposit -> Encode.encodeListLen 4 <> Encode.encodeWord 11 <> credentialEncoding stake <> keyEncoding pool <> Encode.encodeWord64 deposit
  VoteRegistrationDelegation stake drep deposit -> Encode.encodeListLen 4 <> Encode.encodeWord 12 <> credentialEncoding stake <> (Encode.encodePreEncoded . DRep.encodeCbor) drep <> Encode.encodeWord64 deposit
  StakeVoteRegistrationDelegation stake pool drep deposit -> Encode.encodeListLen 5 <> Encode.encodeWord 13 <> credentialEncoding stake <> keyEncoding pool <> (Encode.encodePreEncoded . DRep.encodeCbor) drep <> Encode.encodeWord64 deposit
  AuthorizeCommitteeHot cold hot -> Encode.encodeListLen 3 <> Encode.encodeWord 14 <> credentialEncoding cold <> credentialEncoding hot
  ResignCommitteeCold cold anchor -> Encode.encodeListLen 3 <> Encode.encodeWord 15 <> credentialEncoding cold <> anchorEncoding anchor
  RegisterDRep drep deposit anchor -> Encode.encodeListLen 4 <> Encode.encodeWord 16 <> credentialEncoding drep <> Encode.encodeWord64 deposit <> anchorEncoding anchor
  UnregisterDRep drep refund -> Encode.encodeListLen 3 <> Encode.encodeWord 17 <> credentialEncoding drep <> Encode.encodeWord64 refund
  UpdateDRep drep anchor -> Encode.encodeListLen 3 <> Encode.encodeWord 18 <> credentialEncoding drep <> anchorEncoding anchor

credentialEncoding :: Credential.Credential purpose -> Encode.Encoding
credentialEncoding credential =
  Encode.encodeListLen 2 <> case credential of
    Credential.KeyCredential hash -> Encode.encodeWord 0 <> keyEncoding hash
    Credential.ScriptCredential hash -> Encode.encodeWord 1 <> Encode.encodeBytes (Credential.scriptHashBytes hash)

keyEncoding :: Credential.KeyHash purpose -> Encode.Encoding
keyEncoding = Encode.encodeBytes . Credential.keyHashBytes

anchorEncoding :: Maybe Anchor.Anchor -> Encode.Encoding
anchorEncoding = maybe Encode.encodeNull (Encode.encodePreEncoded . Anchor.encodeCbor)

mirEncoding :: Mir -> Encode.Encoding
mirEncoding rewards =
  Encode.encodeListLen 2 <> case rewards of
    ToOtherPot source amount -> potEncoding source <> Encode.encodeWord64 amount
    ToStakeCredentials source amounts -> potEncoding source <> Encode.encodeMapLen (fromIntegral (Map.size amounts)) <> foldMap (\(credential, amount) -> credentialEncoding credential <> Encode.encodeWord64 amount) (Map.toAscList amounts)

potEncoding :: Pot -> Encode.Encoding
potEncoding Reserves = Encode.encodeWord 0
potEncoding Treasury = Encode.encodeWord 1

certificateDecoder :: Decode.Decoder s Certificate
certificateDecoder = do
  size <- Decode.decodeListLenOrIndef
  kind <- Decode.decodeWord
  value <- case kind of
    0 -> checkSize 2 size >> (StakeRegistration <$> credentialDecoder)
    1 -> checkSize 2 size >> (StakeDeregistration <$> credentialDecoder)
    2 -> checkSize 3 size >> (StakeDelegation <$> credentialDecoder <*> keyDecoder)
    3 -> do
      (fields, parameters) <- Pool.parametersDecoderWithFieldCount
      checkSize (1 + fromIntegral fields) size
      pure (PoolRegistration parameters)
    4 -> checkSize 3 size >> (PoolRetirement <$> keyDecoder <*> Decode.decodeWord64)
    5 -> checkSize 4 size >> (GenesisKeyDelegation <$> keyDecoder <*> keyDecoder <*> (validated Pool.vrfKeyHashFromBytes =<< Decode.decodeBytes))
    6 -> checkSize 2 size >> (MoveInstantaneousRewards <$> mirDecoder)
    7 -> checkSize 3 size >> (Registration <$> credentialDecoder <*> Decode.decodeWord64)
    8 -> checkSize 3 size >> (Unregistration <$> credentialDecoder <*> Decode.decodeWord64)
    9 -> checkSize 3 size >> (VoteDelegation <$> credentialDecoder <*> embedded DRep.decodeCbor)
    10 -> checkSize 4 size >> (StakeVoteDelegation <$> credentialDecoder <*> keyDecoder <*> embedded DRep.decodeCbor)
    11 -> checkSize 4 size >> (StakeRegistrationDelegation <$> credentialDecoder <*> keyDecoder <*> Decode.decodeWord64)
    12 -> checkSize 4 size >> (VoteRegistrationDelegation <$> credentialDecoder <*> embedded DRep.decodeCbor <*> Decode.decodeWord64)
    13 -> checkSize 5 size >> (StakeVoteRegistrationDelegation <$> credentialDecoder <*> keyDecoder <*> embedded DRep.decodeCbor <*> Decode.decodeWord64)
    14 -> checkSize 3 size >> (AuthorizeCommitteeHot <$> credentialDecoder <*> credentialDecoder)
    15 -> checkSize 3 size >> (ResignCommitteeCold <$> credentialDecoder <*> anchorDecoder)
    16 -> checkSize 4 size >> (RegisterDRep <$> credentialDecoder <*> Decode.decodeWord64 <*> anchorDecoder)
    17 -> checkSize 3 size >> (UnregisterDRep <$> credentialDecoder <*> Decode.decodeWord64)
    18 -> checkSize 3 size >> (UpdateDRep <$> credentialDecoder <*> anchorDecoder)
    _ -> fail "Unknown certificate kind"
  endArray size
  pure value

credentialDecoder :: Decode.Decoder s (Credential.Credential purpose)
credentialDecoder = arrayOf 2 $ do
  kind <- Decode.decodeWord
  case kind of
    0 -> Credential.KeyCredential <$> keyDecoder
    1 -> Credential.ScriptCredential <$> (validated Credential.scriptHashFromBytes =<< Decode.decodeBytes)
    _ -> fail "Unknown credential kind"

keyDecoder :: Decode.Decoder s (Credential.KeyHash purpose)
keyDecoder = validated Credential.keyHashFromBytes =<< Decode.decodeBytes

anchorDecoder :: Decode.Decoder s (Maybe Anchor.Anchor)
anchorDecoder = do
  token <- Decode.peekTokenType
  if token == Decode.TypeNull then Decode.decodeNull >> pure Nothing else Just <$> embedded Anchor.decodeCbor

mirDecoder :: Decode.Decoder s Mir
mirDecoder = arrayOf 2 $ do
  code <- Decode.decodeWord
  source <- case code of
    0 -> pure Reserves
    1 -> pure Treasury
    _ -> fail "Unknown rewards pot"
  token <- Decode.peekTokenType
  if token == Decode.TypeMapLen || token == Decode.TypeMapLenIndef
    then ToStakeCredentials source <$> rewardsDecoder
    else ToOtherPot source <$> Decode.decodeWord64

rewardsDecoder :: Decode.Decoder s (Map (Credential.Credential Credential.Stake) Word64)
rewardsDecoder = do
  size <- Decode.decodeMapLenOrIndef
  entries <- sequenceEntries size ((,) <$> credentialDecoder <*> Decode.decodeWord64)
  foldM insertReward Map.empty entries
  where
    insertReward amounts (credential, amount)
      | Map.member credential amounts = fail "Duplicate rewards credential"
      | otherwise = pure (Map.insert credential amount amounts)

certificatesDecoder :: Decode.Decoder s Certificates
certificatesDecoder = do
  token <- Decode.peekTokenType
  when (token == Decode.TypeTag) $ do
    tag <- Decode.decodeTag
    unless (tag == 258) (fail "Expected certificate set tag 258")
  size <- Decode.decodeListLenOrIndef
  Certificates <$> sequenceEntries size certificateDecoder

sequenceEntries :: Maybe Int -> Decode.Decoder s a -> Decode.Decoder s [a]
sequenceEntries size entry = case size of
  Just count -> replicateM count entry
  Nothing -> go
  where
    go = do
      ended <- Decode.decodeBreakOr
      if ended then pure [] else (:) <$> entry <*> go

embedded :: (ByteString -> Either Error a) -> Decode.Decoder s a
embedded decode = do
  term <- Term.decodeTerm
  validated decode (Write.toStrictByteString (Term.encodeTerm term))

arrayOf :: Int -> Decode.Decoder s a -> Decode.Decoder s a
arrayOf expected entry = do
  size <- Decode.decodeListLenOrIndef
  checkSize expected size
  value <- entry
  endArray size
  pure value

checkSize :: Int -> Maybe Int -> Decode.Decoder s ()
checkSize expected size = case size of
  Just actual -> unless (actual == expected) (fail "Incorrect certificate array length")
  Nothing -> pure ()

endArray :: Maybe Int -> Decode.Decoder s ()
endArray size = case size of
  Just _ -> pure ()
  Nothing -> do
    ended <- Decode.decodeBreakOr
    unless ended (fail "Extra certificate array elements")

validated :: (a -> Either Error b) -> a -> Decode.Decoder s b
validated validate value = either (fail . show) pure (validate value)

decodeComplete :: (forall s. Decode.Decoder s a) -> ByteString -> Either Error a
decodeComplete decoder bytes = case Read.deserialiseFromBytes decoder (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidCertificateCbor (Text.pack (show failure)))
  Right (remaining, value)
    | Lazy.null remaining -> Right value
    | otherwise -> Left (InvalidCertificateCbor "Trailing bytes after certificate value")
