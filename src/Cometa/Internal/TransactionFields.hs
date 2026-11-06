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

-- | Fields shared by ordinary transaction bodies and Dijkstra subtransaction
-- bodies. Construct defaults with 'fields', then update typed optional fields.
-- Absence and a present empty collection are distinct where represented.
--
-- @
-- noOptionalFields = fields [] []
-- @
module Cometa.Internal.TransactionFields
  ( Fields (..),
    fields,
    Mint,
    mkMint,
    mintValue,
    Entries,
    mkEntries,
    entries,
    BalanceInterval (..),
    BodyNetwork (..),
    encodeFields,
    decodeFields,
    validateFields,
    encodeIntervals,
    decodeIntervals,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Address.Reward (RewardAddress)
import qualified Cometa.Address.Reward as Reward
import Cometa.Certificate.Collection (Certificates)
import qualified Cometa.Certificate.Collection as Certificates
import Cometa.Credential (Credential, Guard)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import Cometa.Governance.Proposal (Proposals)
import qualified Cometa.Governance.Proposal as Proposal
import Cometa.Governance.Voting (VotingProcedures)
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.ProposalCbor as P
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Internal.TransactionValue as V
import Cometa.PlutusData (EncodedPlutusData)
import qualified Cometa.PlutusData as Data
import Cometa.Transaction.Datum (Hash32)
import qualified Cometa.Transaction.Datum as Datum
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Input as Input
import Cometa.Transaction.Output (Output)
import qualified Cometa.Transaction.Output as Output
import Cometa.Value (Value)
import qualified Cometa.Value as Value
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Nonempty unique-key association. Equality compares keys and values, ignoring
-- insertion order. Construction rejects duplicate keys even when values agree.
newtype Entries key value = Entries (Map key value) deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate a nonempty collection of unique keys. Empty or duplicate-key input
-- returns 'InvalidTransactionField'. No entry is silently overwritten.
mkEntries :: (Ord key) => [(key, value)] -> Either Error (Entries key value)
mkEntries pairs
  | null pairs = Left (InvalidTransactionField "Empty transaction association")
  | Map.size result /= length pairs = Left (InvalidTransactionField "Duplicate transaction association key")
  | otherwise = Right (Entries result)
  where
    result = Map.fromList pairs

-- | Entries in ascending key order, independent of insertion order.
entries :: Entries key value -> [(key, value)]
entries (Entries result) = Map.toAscList result

-- | Signed native-asset mint/burn quantities, each within int64. Ada is excluded.
-- Equality compares normalized quantities; zero entries disappear.
newtype Mint = Mint Value deriving (Eq, Show)

-- | Validate signed native-asset quantities and exclude Ada. Quantity overflow
-- returns 'InvalidTransactionOutputValue'; Ada returns 'InvalidTransactionField'.
mkMint :: Value -> Either Error Mint
mkMint value = V.validateMint value >> pure (Mint value)

-- | Signed asset quantities; positive creates units and negative burns them.
mintValue :: Mint -> Value
mintValue (Mint result) = result

-- | Dijkstra account-balance condition, measured in lovelace. Range lower bound
-- is inclusive and upper bound is exclusive; Nothing leaves that side unbounded.
-- Representability does not establish satisfiability against ledger account state.
data BalanceInterval
  = -- | Require exactly this unsigned 64-bit balance.
    ExactBalance !Word64
  | -- | Inclusive lower bound and exclusive upper bound, respectively.
    BalanceRange !(Maybe Word64) !(Maybe Word64)
  deriving (Eq, Show)

-- | Shared body data. Collections preserve order and duplicates except unique-key
-- 'Entries'. Optional values distinguish field absence from present zero/empty.
-- No fee, collateral or nested subtransactions occur in this shared record.
data Fields = Fields
  { -- | Spending references. Fresh encoding and decoding sort by hash/index,
    -- retaining duplicate references as the native input collection does.
    -- A reference need not exist on chain.
    fieldInputs :: ![Input],
    -- | Outputs in creation order; the index in this list identifies an output.
    fieldOutputs :: ![Output],
    -- | Exclusive upper validity slot, from zero through 2^64 - 1.
    fieldInvalidAfter :: !(Maybe Word64),
    -- | Ordered certificates, retaining duplicate instructions.
    fieldCertificates :: !(Maybe Certificates),
    -- | Nonempty reward-account to withdrawn-lovelace association.
    fieldWithdrawals :: !(Maybe (Entries RewardAddress Word64)),
    -- | Expected 32-byte auxiliary-data digest, without verifying auxiliary data.
    fieldAuxiliaryDataHash :: !(Maybe Hash32),
    -- | Inclusive lower validity slot, from zero through 2^64 - 1.
    fieldInvalidBefore :: !(Maybe Word64),
    -- | Optional signed mint/burn instructions, excluding Ada.
    fieldMint :: !(Maybe Mint),
    -- | Expected 32-byte script-integrity digest, without computing it.
    fieldScriptDataHash :: !(Maybe Hash32),
    -- | Required signing/guard credentials. Key and script guards are distinct.
    fieldGuards :: !(Maybe [Credential Guard]),
    -- | Optional network tag. Body CBOR permits mainnet 1 or testnet 0 only.
    fieldNetworkId :: !(Maybe BodyNetwork),
    -- | References made available to scripts without spending them. Fresh
    -- encoding and decoding sort by hash/index and retain duplicates.
    fieldReferenceInputs :: !(Maybe [Input]),
    -- | Unique voter/action voting instructions.
    fieldVotingProcedures :: !(Maybe VotingProcedures),
    -- | Ordered governance proposals; order determines proposal indices.
    fieldProposalProcedures :: !(Maybe Proposals),
    -- | Current treasury value claimed by the transaction, in lovelace.
    fieldTreasuryValue :: !(Maybe Word64),
    -- | Treasury donation in lovelace; a present zero differs from absence.
    fieldDonation :: !(Maybe Word64),
    -- | Dijkstra top-level required guard credential and optional exact datum.
    fieldRequiredTopLevelGuards :: !(Maybe (Entries (Credential Guard) (Maybe EncodedPlutusData))),
    -- | Dijkstra direct deposits to reward accounts, measured in lovelace.
    fieldDirectDeposits :: !(Maybe (Entries RewardAddress Word64)),
    -- | Dijkstra account-balance requirements for this body.
    fieldAccountBalanceIntervals :: !(Maybe (Entries RewardAddress BalanceInterval))
  }
  deriving (Eq, Show)

-- | Transaction bodies carry one of the two ledger network alternatives.
data BodyNetwork = Testnet | Mainnet deriving (Eq, Ord, Show, Enum, Bounded)

-- | Required inputs and outputs, with every optional field absent. Lists may be
-- empty: this is structural assembly and does not establish ledger admission.
fields :: [Input] -> [Output] -> Fields
fields inputs outputs = Fields (sort inputs) outputs Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | Internal field serializer shared by the two body schemas.
encodeFields :: Fields -> [(Word64, E.Encoding)]
encodeFields value =
  [(0, inputSet (fieldInputs value)), (1, outputList (fieldOutputs value))]
    ++ optional 3 E.encodeWord64 (fieldInvalidAfter value)
    ++ optional 4 (Cbor.raw . Certificates.encodeCbor) (fieldCertificates value)
    ++ optional 5 (association (E.encodeBytes . Reward.toBytes) E.encodeWord64) (fieldWithdrawals value)
    ++ optional 7 hashEncoding (fieldAuxiliaryDataHash value)
    ++ optional 8 E.encodeWord64 (fieldInvalidBefore value)
    ++ optional 9 (V.encodeAssets . mintValue) (fieldMint value)
    ++ optional 11 hashEncoding (fieldScriptDataHash value)
    ++ optional 14 guardSet (fieldGuards value)
    ++ optional 15 (E.encodeWord . fromIntegral . fromEnum) (fieldNetworkId value)
    ++ optional 18 inputSet (fieldReferenceInputs value)
    ++ optional 19 (Cbor.raw . Voting.encodeCbor) (fieldVotingProcedures value)
    ++ optional 20 (Cbor.raw . Proposal.encodeProposals) (fieldProposalProcedures value)
    ++ optional 21 E.encodeWord64 (fieldTreasuryValue value)
    ++ optional 22 E.encodeWord64 (fieldDonation value)
    ++ optional 24 (association P.credentialEncoding (maybe E.encodeNull (Cbor.raw . Data.toCbor))) (fieldRequiredTopLevelGuards value)
    ++ optional 25 (association (E.encodeBytes . Reward.toBytes) E.encodeWord64) (fieldDirectDeposits value)
    ++ optional 26 (association (E.encodeBytes . Reward.toBytes) intervalEncoding) (fieldAccountBalanceIntervals value)
  where
    optional key enc = maybe [] (\payload -> [(key, enc payload)])
    hashEncoding = E.encodeBytes . Datum.hashBytes

inputSet :: [Input] -> E.Encoding
inputSet values = E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Input.encodeCbor) (sort values)

outputList :: [Output] -> E.Encoding
outputList values = E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Output.encodeCbor) values

association :: (key -> E.Encoding) -> (value -> E.Encoding) -> Entries key value -> E.Encoding
association encodeKey encodeValue values = E.encodeMapLen (fromIntegral (length pairs)) <> foldMap (\(key, value) -> encodeKey key <> encodeValue value) pairs
  where
    pairs = sortOn (Cbor.encode . encodeKey . fst) (entries values)

guardSet :: [Credential Guard] -> E.Encoding
guardSet values = E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap encodeGuard values
  where
    credentialForm = any isScript values
    isScript (Credential.ScriptCredential _) = True
    isScript _ = False
    encodeGuard credential =
      if credentialForm
        then P.credentialEncoding credential
        else case credential of
          Credential.KeyCredential hash -> E.encodeBytes (Credential.keyHashBytes hash)
          Credential.ScriptCredential hash -> E.encodeBytes (Credential.scriptHashBytes hash)

intervalEncoding :: BalanceInterval -> E.Encoding
intervalEncoding interval = case interval of
  ExactBalance coin -> E.encodeWord64 coin
  BalanceRange lower upper -> E.encodeListLen 2 <> maybe E.encodeNull E.encodeWord64 lower <> maybe E.encodeNull E.encodeWord64 upper

-- | Internal shared-schema decoder. Each nested payload is decoded against its
-- exact original slice; containing-body identity never depends on re-encoding.
decodeFields :: Map Word64 ByteString -> Either Error Fields
decodeFields values =
  Fields
    <$> required 0 inputDecoder
    <*> required 1 outputDecoder
    <*> optional 3 word
    <*> optional 4 (fmap Certificates.toCertificates . Certificates.decodeCbor)
    <*> optional 5 (associationDecoder rewardDecoder D.decodeWord64)
    <*> optional 7 hashDecoder
    <*> optional 8 word
    <*> optional 9 mintDecoder
    <*> optional 11 hashDecoder
    <*> optional 14 guardsDecoder
    <*> optional 15 networkDecoder
    <*> optional 18 inputDecoder
    <*> optional 19 (fmap Voting.toVotingProcedures . Voting.decodeCbor)
    <*> optional 20 (fmap Proposal.toProposals . Proposal.decodeProposals)
    <*> optional 21 word
    <*> optional 22 word
    <*> optional 24 requiredGuardsDecoder
    <*> optional 25 (associationDecoder rewardDecoder D.decodeWord64)
    <*> optional 26 (associationDecoder rewardDecoder intervalDecoder)
  where
    required key parser = maybe (Left (InvalidTransactionField "Missing required transaction body field")) parser (Map.lookup key values)
    optional key parser = traverse parser (Map.lookup key values)
    word = Cbor.decode D.decodeWord64
    inputDecoder bytes = sort <$> Cbor.decode (Cbor.setList (Cbor.nested bytes Input.decodeCbor)) bytes
    outputDecoder bytes = Cbor.decode (Cbor.list (Output.toOutput <$> Cbor.nested bytes Output.decodeCbor)) bytes
    hashDecoder = Cbor.decode (D.decodeBytes >>= either (fail . show) pure . Datum.hashFromBytes)
    mintDecoder bytes = Cbor.decode V.decodeAssets bytes >>= mkMint
    networkDecoder bytes = do
      value <- Cbor.decode D.decodeWord bytes
      case value of
        0 -> Right Testnet
        1 -> Right Mainnet
        _ -> Left (InvalidTransactionField "Body network id must be 0 or 1")
    guardsDecoder bytes = do
      guards <- Cbor.decode (Cbor.setList guardDecoder) bytes
      unless (Set.size (Set.fromList guards) == length guards) (Left (InvalidTransactionField "Duplicate guard credential"))
      pure guards
    guardDecoder = do
      token <- D.peekTokenType
      if token == D.TypeBytes then Credential.KeyCredential <$> (D.decodeBytes >>= either (fail . show) pure . Credential.keyHashFromBytes) else P.credentialDecoder
    requiredGuardsDecoder bytes = associationDecoder P.credentialDecoder (Cbor.optional (Cbor.nested bytes Data.decodeCbor)) bytes

rewardDecoder :: D.Decoder s RewardAddress
rewardDecoder = D.decodeBytes >>= either (fail . show) pure . Reward.fromBytes

associationDecoder :: (Ord key) => (forall s. D.Decoder s key) -> (forall s. D.Decoder s value) -> ByteString -> Either Error (Entries key value)
associationDecoder keyParser valueParser bytes = Cbor.decode (Cbor.entries ((,) <$> keyParser <*> valueParser)) bytes >>= mkEntries

intervalDecoder :: D.Decoder s BalanceInterval
intervalDecoder = do
  token <- D.peekTokenType
  if token == D.TypeUInt || token == D.TypeUInt64
    then ExactBalance <$> D.decodeWord64
    else Cbor.array 2 (BalanceRange <$> Cbor.optional D.decodeWord64 <*> Cbor.optional D.decodeWord64)

-- | Context checks follow native sub-body restrictions. Imported historical
-- top-level empty guard fields remain inspectable but fresh assembly rejects them.
validateFields :: Bool -> Fields -> Either Error ()
validateFields isSub value = do
  case fieldGuards value of
    Nothing -> pure ()
    Just guards -> do
      when (null guards) (Left (InvalidTransactionField "Present guard set must be nonempty"))
      unless (Set.size (Set.fromList guards) == length guards) (Left (InvalidTransactionField "Duplicate guard credential"))
  when isSub $ do
    case fieldCertificates value of
      Just certs -> when (null (Certificates.toList certs)) (Left (InvalidTransactionField "Present subtransaction certificates must be nonempty"))
      Nothing -> pure ()
    case fieldMint value of
      Just mint -> when (Value.isZero (mintValue mint)) (Left (InvalidTransactionField "Present subtransaction mint must be nonempty"))
      Nothing -> pure ()

-- | Native typed reward-account/interval association codec shared by keys 26/27.
encodeIntervals :: Entries RewardAddress BalanceInterval -> E.Encoding
encodeIntervals = association (E.encodeBytes . Reward.toBytes) intervalEncoding

decodeIntervals :: ByteString -> Either Error (Entries RewardAddress BalanceInterval)
decodeIntervals = associationDecoder rewardDecoder intervalDecoder
