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

-- | Private immutable governance representations and CBOR schemas.
-- No native object is retained. Public modules select the domain operations;
-- parser workers remain private to this module.
module Cometa.Internal.Governance
  ( Url,
    mkUrl,
    urlText,
    DataHash,
    dataHashFromBytes,
    dataHashBytes,
    Anchor (..),
    encodeAnchor,
    decodeAnchor,
    ActionId (..),
    encodeActionId,
    decodeActionId,
    DRep (..),
    encodeDRep,
    decodeDRep,
    Vote (..),
    Voter (..),
    VotingProcedure (..),
    VotingProcedures,
    empty,
    singleton,
    fromList,
    toList,
    insert,
    lookup,
    merge,
    EncodedVotingProcedures,
    encodeVoting,
    decodeVoting,
    fromVotingProcedures,
    toVotingProcedures,
    toCbor,
    encodeVoter,
    decodeVoter,
    encodeProcedure,
    decodeProcedure,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import Cometa.TransactionId (TransactionId)
import qualified Cometa.TransactionId as TransactionId
import Control.Monad (foldM, replicateM, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Prelude hiding (lookup)

-- TYPES ----------------------------------------------------------------------

-- | Metadata location containing 1 through 128 UTF-8 bytes and no NUL.
-- No URI syntax, network reachability, or payload validation is implied.
-- Equality and ordering compare text. 'Show' is diagnostic.
newtype Url = Url Text deriving (Eq, Ord, Show)

-- | An exact 32-byte BLAKE2b-256 digest of off-chain metadata bytes.
-- Importing bytes does not verify metadata. Equality and ordering compare bytes.
newtype DataHash = DataHash ByteString deriving (Eq, Ord, Show)

-- | A metadata location and the expected hash of its payload. Assembly is total
-- because both components are validated. A location does not authenticate data
-- unless the retrieved bytes are checked against the hash.
data Anchor = Anchor
  { -- | Off-chain metadata location.
    url :: !Url,
    -- | Expected digest of the exact off-chain payload bytes.
    dataHash :: !DataHash
  }
  deriving (Eq, Ord, Show)

-- | A proposal's identity: the transaction containing it and its zero-based
-- index within that transaction. The standalone native schema permits the full
-- unsigned 64-bit index range. This does not establish ledger acceptance of an
-- index in a particular era. Ordering compares transaction bytes, then index.
data ActionId = ActionId
  { -- | Transaction-body hash of the transaction containing the proposal.
    transactionId :: !TransactionId,
    -- | Zero-based proposal index, from 0 through 2^64 - 1.
    index :: !Word64
  }
  deriving (Eq, Ord, Show)

-- | A delegation target. The two special targets are not voting authorities;
-- only a credential can identify a DRep voter.
data DRep
  = -- | A key or script DRep credential.
    DRepCredential !(Credential.Credential Credential.DRep)
  | -- | Delegate to the predefined always-abstain target.
    AlwaysAbstain
  | -- | Delegate to the predefined always-no-confidence target.
    AlwaysNoConfidence
  deriving (Eq, Ord, Show)

-- | A governance voting choice. Ordering follows CBOR codes: No=0, Yes=1,
-- Abstain=2. Abstention is an explicit choice, distinct from an absent vote.
data Vote = No | Yes | Abstain deriving (Eq, Ord, Show, Bounded, Enum)

-- | Authority casting a vote. Committee votes use the hot credential;
-- stake pools have key authorities only. Ordering follows native voter codes
-- (committee key/script, DRep key/script, pool key), then exact hash bytes.
data Voter
  = -- | Constitutional committee hot key or script.
    CommitteeVoter !(Credential.Credential Credential.CommitteeHot)
  | -- | DRep key or script; special delegation targets cannot vote.
    DRepVoter !(Credential.Credential Credential.DRep)
  | -- | Stake pool verification-key hash.
    StakePoolVoter !(Credential.KeyHash Credential.StakePool)
  deriving (Eq, Ord, Show)

-- | A voting choice and optional explanation. 'Nothing' encodes as CBOR null;
-- a present anchor carries a validated metadata location and payload hash.
data VotingProcedure = VotingProcedure
  { -- | Explicit choice on the proposal.
    vote :: !Vote,
    -- | Optional off-chain explanation.
    anchor :: !(Maybe Anchor)
  }
  deriving (Eq, Ord, Show)

-- | At most one procedure for each voter/action pair. Empty is valid; stored
-- voters always have at least one procedure. Equality is semantic; ordering
-- compares sorted voter/action entries and their procedures. 'Show' is diagnostic.
newtype VotingProcedures = VotingProcedures (Map Voter (Map ActionId VotingProcedure))
  deriving (Eq, Ord, Show)

-- | Voting data with its exact original CBOR encoding. Equality and ordering
-- compare encoded bytes; 'toVotingProcedures' permits semantic comparison.
-- Imported map order and nonminimal encodings remain observable through 'toCbor'.
data EncodedVotingProcedures = EncodedVotingProcedures !ByteString !VotingProcedures
  deriving (Show)

instance Eq EncodedVotingProcedures where
  left == right = toCbor left == toCbor right

instance Ord EncodedVotingProcedures where
  compare left right = compare (toCbor left) (toCbor right)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate 1 through 128 UTF-8 bytes and absence of NUL. Bad length returns
-- 'InvalidAnchorUrlLength'; NUL returns 'InvalidAnchorUrl'. No URI parsing or
-- network request occurs.
mkUrl :: Text -> Either Error Url
mkUrl value
  | size < 1 || size > 128 = Left (InvalidAnchorUrlLength size)
  | Text.any (== '\0') value = Left InvalidAnchorUrl
  | otherwise = Right (Url value)
  where
    size = ByteString.length (Text.encodeUtf8 value)

-- | Exact validated location text.
urlText :: Url -> Text
urlText (Url value) = value

-- | Import exactly 32 bytes without hashing. Another length returns
-- 'InvalidAnchorDataHashLength' with the actual byte count.
dataHashFromBytes :: ByteString -> Either Error DataHash
dataHashFromBytes bytes
  | ByteString.length bytes == 32 = Right (DataHash bytes)
  | otherwise = Left (InvalidAnchorDataHashLength (ByteString.length bytes))

-- | Exact expected payload hash bytes.
dataHashBytes :: DataHash -> ByteString
dataHashBytes (DataHash bytes) = bytes

-- | No votes.
empty :: VotingProcedures
empty = VotingProcedures Map.empty

-- | One voter casting one procedure on one action. All arguments are validated
-- domain values, so assembly cannot fail.
singleton :: Voter -> ActionId -> VotingProcedure -> VotingProcedures
singleton voter action procedure = VotingProcedures (Map.singleton voter (Map.singleton action procedure))

-- | Assemble triples in any order. Repeating a voter/action pair returns
-- 'DuplicateGovernanceVote', even when the procedures agree. No vote is discarded.
fromList :: [(Voter, ActionId, VotingProcedure)] -> Either Error VotingProcedures
fromList = foldM (\votes (voter, action, procedure) -> insert voter action procedure votes) empty

-- | Entries sorted by voter kind/hash, then transaction hash/index. Input
-- insertion order is not retained by this semantic collection.
toList :: VotingProcedures -> [(Voter, ActionId, VotingProcedure)]
toList (VotingProcedures voters) =
  [(voter, action, procedure) | (voter, actions) <- Map.toAscList voters, (action, procedure) <- Map.toAscList actions]

-- | Add a vote, rejecting an existing voter/action pair with
-- 'DuplicateGovernanceVote'. Other votes remain unchanged.
insert :: Voter -> ActionId -> VotingProcedure -> VotingProcedures -> Either Error VotingProcedures
insert voter action procedure (VotingProcedures voters)
  | Map.member action actions = Left DuplicateGovernanceVote
  | otherwise = Right (VotingProcedures (Map.insert voter (Map.insert action procedure actions) voters))
  where
    actions = Map.findWithDefault Map.empty voter voters

-- | Find the procedure for a voter/action pair; absence is legitimate.
lookup :: Voter -> ActionId -> VotingProcedures -> Maybe VotingProcedure
lookup voter action (VotingProcedures voters) = Map.lookup voter voters >>= Map.lookup action

-- | Combine disjoint voter/action pairs. Any overlap returns
-- 'DuplicateGovernanceVote', even when both votes agree. Successful merge is
-- associative and commutative, with 'empty' as its identity.
merge :: VotingProcedures -> VotingProcedures -> Either Error VotingProcedures
merge left right = foldM (\votes (voter, action, procedure) -> insert voter action procedure votes) left (toList right)

encodeAnchor :: Anchor -> ByteString
encodeAnchor = Write.toStrictByteString . anchorEncoding

decodeAnchor :: ByteString -> Either Error Anchor
decodeAnchor = decodeComplete anchorDecoder

encodeActionId :: ActionId -> ByteString
encodeActionId = Write.toStrictByteString . actionEncoding

decodeActionId :: ByteString -> Either Error ActionId
decodeActionId = decodeComplete actionDecoder

encodeDRep :: DRep -> ByteString
encodeDRep = Write.toStrictByteString . drepEncoding

decodeDRep :: ByteString -> Either Error DRep
decodeDRep = decodeComplete drepDecoder

encodeVoter :: Voter -> ByteString
encodeVoter = Write.toStrictByteString . voterEncoding

decodeVoter :: ByteString -> Either Error Voter
decodeVoter = decodeComplete voterDecoder

encodeProcedure :: VotingProcedure -> ByteString
encodeProcedure = Write.toStrictByteString . procedureEncoding

decodeProcedure :: ByteString -> Either Error VotingProcedure
decodeProcedure = decodeComplete procedureDecoder

-- | Serialize fresh data in native voter/hash/index order with definite maps,
-- definite arrays and shortest integer encodings. Re-encoding semantic data
-- inspected from external CBOR can change transaction identity; use 'toCbor'
-- on the encoded wrapper to retain imported bytes.
encodeVoting :: VotingProcedures -> ByteString
encodeVoting = Write.toStrictByteString . votingEncoding

-- | Decode exactly one complete nested voting map. Definite and indefinite
-- containers and nonminimal unsigned integers are accepted. Duplicate voter
-- keys, duplicate voter/action pairs and empty inner maps are rejected rather
-- than merged or discarded. Invalid schema, bounds, UTF-8, or trailing bytes
-- returns 'InvalidGovernanceCbor'. Original bytes are preserved unchanged.
decodeVoting :: ByteString -> Either Error EncodedVotingProcedures
decodeVoting bytes = EncodedVotingProcedures bytes <$> decodeComplete votingDecoder bytes

-- | Assign fresh minimal, sorted CBOR to a semantic collection.
fromVotingProcedures :: VotingProcedures -> EncodedVotingProcedures
fromVotingProcedures value = EncodedVotingProcedures (encodeVoting value) value

-- | Inspect votes without changing their preserved encoding.
toVotingProcedures :: EncodedVotingProcedures -> VotingProcedures
toVotingProcedures (EncodedVotingProcedures _ value) = value

-- | The exact imported encoding, or the fresh encoding assigned by
-- 'fromVotingProcedures'.
toCbor :: EncodedVotingProcedures -> ByteString
toCbor (EncodedVotingProcedures bytes _) = bytes

anchorEncoding :: Anchor -> Encode.Encoding
anchorEncoding (Anchor location digest) = Encode.encodeListLen 2 <> Encode.encodeString (urlText location) <> Encode.encodeBytes (dataHashBytes digest)

actionEncoding :: ActionId -> Encode.Encoding
actionEncoding (ActionId hash actionIndex) = Encode.encodeListLen 2 <> Encode.encodeBytes (TransactionId.toBytes hash) <> Encode.encodeWord64 actionIndex

credentialEncoding :: Credential.Credential purpose -> Encode.Encoding
credentialEncoding credential = case credential of
  Credential.KeyCredential hash -> Encode.encodeWord 0 <> Encode.encodeBytes (Credential.keyHashBytes hash)
  Credential.ScriptCredential hash -> Encode.encodeWord 1 <> Encode.encodeBytes (Credential.scriptHashBytes hash)

drepEncoding :: DRep -> Encode.Encoding
drepEncoding drep = case drep of
  DRepCredential credential -> Encode.encodeListLen 2 <> credentialEncoding credential
  AlwaysAbstain -> Encode.encodeListLen 1 <> Encode.encodeWord 2
  AlwaysNoConfidence -> Encode.encodeListLen 1 <> Encode.encodeWord 3

voterEncoding :: Voter -> Encode.Encoding
voterEncoding voter =
  Encode.encodeListLen 2 <> case voter of
    CommitteeVoter credential -> credentialEncoding credential
    DRepVoter credential -> case credential of
      Credential.KeyCredential hash -> Encode.encodeWord 2 <> Encode.encodeBytes (Credential.keyHashBytes hash)
      Credential.ScriptCredential hash -> Encode.encodeWord 3 <> Encode.encodeBytes (Credential.scriptHashBytes hash)
    StakePoolVoter hash -> Encode.encodeWord 4 <> Encode.encodeBytes (Credential.keyHashBytes hash)

procedureEncoding :: VotingProcedure -> Encode.Encoding
procedureEncoding (VotingProcedure choice explanation) = Encode.encodeListLen 2 <> Encode.encodeWord (voteCode choice) <> maybe Encode.encodeNull anchorEncoding explanation

votingEncoding :: VotingProcedures -> Encode.Encoding
votingEncoding (VotingProcedures voters) = Encode.encodeMapLen (fromIntegral (Map.size voters)) <> foldMap encodeVoterVotes (Map.toAscList voters)
  where
    encodeVoterVotes (voter, actions) = voterEncoding voter <> Encode.encodeMapLen (fromIntegral (Map.size actions)) <> foldMap (\(action, procedure) -> actionEncoding action <> procedureEncoding procedure) (Map.toAscList actions)

voteCode :: Vote -> Word
voteCode No = 0
voteCode Yes = 1
voteCode Abstain = 2

anchorDecoder :: Decode.Decoder s Anchor
anchorDecoder = arrayOf 2 $ do
  location <- validated mkUrl =<< Decode.decodeString
  digest <- validated dataHashFromBytes =<< Decode.decodeBytes
  pure (Anchor location digest)

actionDecoder :: Decode.Decoder s ActionId
actionDecoder = arrayOf 2 $ do
  hash <- validated TransactionId.fromBytes =<< Decode.decodeBytes
  ActionId hash <$> Decode.decodeWord64

credentialDecoder :: Word -> Decode.Decoder s (Credential.Credential purpose)
credentialDecoder kind = do
  bytes <- Decode.decodeBytes
  case kind of
    0 -> Credential.KeyCredential <$> validated Credential.keyHashFromBytes bytes
    1 -> Credential.ScriptCredential <$> validated Credential.scriptHashFromBytes bytes
    _ -> fail "Invalid credential kind"

drepDecoder :: Decode.Decoder s DRep
drepDecoder = do
  size <- Decode.decodeListLenOrIndef
  kind <- Decode.decodeWord
  let expected = if kind < 2 then 2 else 1
  checkSize expected size
  value <- case kind of
    0 -> DRepCredential <$> credentialDecoder 0
    1 -> DRepCredential <$> credentialDecoder 1
    2 -> pure AlwaysAbstain
    3 -> pure AlwaysNoConfidence
    _ -> fail "Invalid DRep kind"
  endArray size
  pure value

voterDecoder :: Decode.Decoder s Voter
voterDecoder = arrayOf 2 $ do
  kind <- Decode.decodeWord
  case kind of
    0 -> CommitteeVoter <$> credentialDecoder 0
    1 -> CommitteeVoter <$> credentialDecoder 1
    2 -> DRepVoter <$> credentialDecoder 0
    3 -> DRepVoter <$> credentialDecoder 1
    4 -> StakePoolVoter <$> (validated Credential.keyHashFromBytes =<< Decode.decodeBytes)
    _ -> fail "Invalid voter kind"

procedureDecoder :: Decode.Decoder s VotingProcedure
procedureDecoder = arrayOf 2 $ do
  code <- Decode.decodeWord
  choice <- case code of
    0 -> pure No
    1 -> pure Yes
    2 -> pure Abstain
    _ -> fail "Invalid vote code"
  token <- Decode.peekTokenType
  explanation <- if token == Decode.TypeNull then Decode.decodeNull >> pure Nothing else Just <$> anchorDecoder
  pure (VotingProcedure choice explanation)

votingDecoder :: Decode.Decoder s VotingProcedures
votingDecoder = do
  pairs <- mapEntries $ do
    voter <- voterDecoder
    actions <- mapEntries ((,) <$> actionDecoder <*> procedureDecoder)
    when (null actions) (fail "Empty inner voting map")
    pure (voter, actions)
  voters <- foldM addVoter Map.empty pairs
  pure (VotingProcedures voters)
  where
    addVoter voters (voter, actions)
      | Map.member voter voters = fail "Duplicate voter key"
      | otherwise = do
          unique <- foldM addAction Map.empty actions
          pure (Map.insert voter unique voters)
    addAction actions (action, procedure)
      | Map.member action actions = fail "Duplicate governance action key"
      | otherwise = pure (Map.insert action procedure actions)

mapEntries :: Decode.Decoder s a -> Decode.Decoder s [a]
mapEntries entry = do
  size <- Decode.decodeMapLenOrIndef
  case size of
    Just count -> replicateM count entry
    Nothing -> go
  where
    go = do
      ended <- Decode.decodeBreakOr
      if ended then pure [] else (:) <$> entry <*> go

arrayOf :: Int -> Decode.Decoder s a -> Decode.Decoder s a
arrayOf expected entry = do
  size <- Decode.decodeListLenOrIndef
  checkSize expected size
  value <- entry
  endArray size
  pure value

checkSize :: Int -> Maybe Int -> Decode.Decoder s ()
checkSize expected size = case size of
  Just actual -> unless (actual == expected) (fail "Incorrect governance array length")
  Nothing -> pure ()

endArray :: Maybe Int -> Decode.Decoder s ()
endArray size = case size of
  Just _ -> pure ()
  Nothing -> do
    ended <- Decode.decodeBreakOr
    unless ended (fail "Extra governance array elements")

validated :: (a -> Either Error b) -> a -> Decode.Decoder s b
validated validate value = either (fail . show) pure (validate value)

decodeComplete :: (forall s. Decode.Decoder s a) -> ByteString -> Either Error a
decodeComplete decoder bytes = case Read.deserialiseFromBytes decoder (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidGovernanceCbor (Text.pack (show failure)))
  Right (remaining, value)
    | Lazy.null remaining -> Right value
    | otherwise -> Left (InvalidGovernanceCbor "Trailing bytes after governance value")
