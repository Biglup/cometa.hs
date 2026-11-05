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

-- | Seven governance action alternatives assembled from validated components.
-- For example, @NoConfidence Nothing@ starts a new committee confidence chain.
-- These values describe proposals; they do not establish ledger eligibility.
module Cometa.Governance.Action
  ( Action (..),
    Removals,
    removalsFromList,
    removalsToList,
    Withdrawals,
    withdrawalsFromList,
    withdrawalsToList,
    EncodedAction,
    encodeCbor,
    decodeCbor,
    fromAction,
    toAction,
    toCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Address.Reward (RewardAddress)
import qualified Cometa.Address.Reward as Reward
import Cometa.Credential (CommitteeCold, Credential, ScriptHash)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import Cometa.Governance.ActionId (ActionId)
import qualified Cometa.Governance.ActionId as ActionId
import Cometa.Governance.Committee (Members)
import qualified Cometa.Governance.Committee as Committee
import Cometa.Governance.Constitution (Constitution)
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Internal.ProposalCbor as Cbor
import Cometa.Protocol.Parameters.Update (Update)
import qualified Cometa.Protocol.Parameters.Update as Update
import Cometa.Protocol.Version (ProtocolVersion)
import qualified Cometa.Protocol.Version as Version
import Cometa.UnitInterval (UnitInterval)
import qualified Cometa.UnitInterval as Interval
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Cold credentials to remove, sorted by kind and hash. Repeated credentials
-- are retained. Ledger acceptance is a separate check.
newtype Removals = Removals [Credential CommitteeCold] deriving (Eq, Ord, Show)

-- | Unique reward accounts and lovelace amounts, including zero amounts.
newtype Withdrawals = Withdrawals (Map RewardAddress Word64) deriving (Eq, Ord, Show)

-- | A governance action. Optional predecessors reference the preceding action
-- of the corresponding purpose; 'Nothing' starts a chain. Optional script hashes
-- identify guardrails policies. Amounts and expiry epochs use unsigned 64-bit units.
data Action
  = -- | Previous parameter action, sparse changes, optional guardrails policy.
    ParameterChange !(Maybe ActionId) !Update !(Maybe ScriptHash)
  | -- | Previous hard-fork action and proposed protocol version.
    HardForkInitiation !(Maybe ActionId) !ProtocolVersion
  | -- | Reward accounts receiving treasury lovelace and optional policy.
    TreasuryWithdrawals !Withdrawals !(Maybe ScriptHash)
  | -- | Previous committee-confidence action.
    NoConfidence !(Maybe ActionId)
  | -- | Previous committee action, removals, additions with expiry, and quorum.
    UpdateCommittee !(Maybe ActionId) !Removals !Members !UnitInterval
  | -- | Previous constitution action and replacement constitution.
    NewConstitution !(Maybe ActionId) !Constitution
  | -- | Informational action without additional fields.
    InfoAction
  deriving (Eq, Show)

-- | Exact original CBOR plus its semantic action. Equality and ordering compare
-- bytes. Use 'toAction' when comparing action meanings.
data EncodedAction = EncodedAction !ByteString !Action deriving (Show)

instance Eq EncodedAction where
  left == right = toCbor left == toCbor right

instance Ord EncodedAction where
  compare left right = compare (toCbor left) (toCbor right)

-- DEFINITIONS ----------------------------------------------------------------

-- | Sort by credential kind then hash bytes, retaining duplicate credentials.
removalsFromList :: [Credential CommitteeCold] -> Removals
removalsFromList = Removals . sort

-- | Sorted removal credentials, including duplicates.
removalsToList :: Removals -> [Credential CommitteeCold]
removalsToList (Removals values) = values

-- | Reject repeated reward accounts with 'DuplicateTreasuryWithdrawal', even
-- when amounts agree. Values are lovelace; no minimum or positivity is imposed.
withdrawalsFromList :: [(RewardAddress, Word64)] -> Either Error Withdrawals
withdrawalsFromList values = Withdrawals <$> Cbor.uniqueMap DuplicateTreasuryWithdrawal values

-- | Entries ordered by exact reward-address bytes, matching fresh serialization.
withdrawalsToList :: Withdrawals -> [(RewardAddress, Word64)]
withdrawalsToList (Withdrawals values) = sortOn (Reward.toBytes . fst) (Map.toList values)

-- | Fresh definite CBOR with shortest integers and sorted maps/removal credentials.
-- Reconstructing semantic data can change transaction identity; 'toCbor' preserves
-- imported bytes instead.
encodeCbor :: Action -> ByteString
encodeCbor = Cbor.encode . actionEncoding

-- | Decode exactly one action and retain its original bytes. Definite and
-- indefinite containers and nonminimal integers are accepted; unknown variants,
-- wrong arity, invalid components, duplicate map keys and trailing data return
-- 'Cometa.Error.InvalidProposalCbor'.
decodeCbor :: ByteString -> Either Error EncodedAction
decodeCbor bytes = EncodedAction bytes <$> Cbor.decode actionDecoder bytes

-- | Assign fresh encoding to semantic data.
fromAction :: Action -> EncodedAction
fromAction value = EncodedAction (encodeCbor value) value

-- | Inspect semantic data without changing retained bytes.
toAction :: EncodedAction -> Action
toAction (EncodedAction _ value) = value

-- | Exact imported encoding, or the encoding assigned by 'fromAction'.
toCbor :: EncodedAction -> ByteString
toCbor (EncodedAction bytes _) = bytes

actionEncoding :: Action -> E.Encoding
actionEncoding value = case value of
  ParameterChange previous changes policy ->
    header 4 0
      <> predecessor previous
      <> Cbor.raw (Update.encodeCbor changes)
      <> policyEncoding policy
  HardForkInitiation previous version -> header 3 1 <> predecessor previous <> Cbor.raw (Version.encodeCbor version)
  TreasuryWithdrawals withdrawals policy -> header 3 2 <> withdrawalsEncoding withdrawals <> policyEncoding policy
  NoConfidence previous -> header 2 3 <> predecessor previous
  UpdateCommittee previous removals members quorum ->
    header 5 4
      <> predecessor previous
      <> removalsEncoding removals
      <> Cbor.raw (Committee.encodeMembers members)
      <> Cbor.raw (Interval.encodeCbor quorum)
  NewConstitution previous constitution -> header 3 5 <> predecessor previous <> Cbor.raw (Constitution.encodeCbor constitution)
  InfoAction -> header 1 6
  where
    header size code = E.encodeListLen size <> E.encodeWord code
    predecessor = Cbor.maybeEncoding (Cbor.raw . ActionId.encodeCbor)

policyEncoding :: Maybe ScriptHash -> E.Encoding
policyEncoding = Cbor.maybeEncoding (E.encodeBytes . Credential.scriptHashBytes)

removalsEncoding :: Removals -> E.Encoding
removalsEncoding (Removals values) = E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap Cbor.credentialEncoding values

withdrawalsEncoding :: Withdrawals -> E.Encoding
withdrawalsEncoding value =
  E.encodeMapLen (fromIntegral (length values))
    <> foldMap (\(account, amount) -> E.encodeBytes (Reward.toBytes account) <> E.encodeWord64 amount) values
  where
    values = withdrawalsToList value

actionDecoder :: D.Decoder s Action
actionDecoder = do
  size <- D.decodeListLenOrIndef
  kind <- D.decodeWord
  let expected = case kind of 0 -> 4; 1 -> 3; 2 -> 3; 3 -> 2; 4 -> 5; 5 -> 3; _ -> 1
  case size of
    Just actual -> unless (actual == expected) (fail "Incorrect action arity")
    Nothing -> pure ()
  value <- variantDecoder kind
  Cbor.finishArray size
  pure value

variantDecoder :: Word -> D.Decoder s Action
variantDecoder kind = case kind of
  0 -> ParameterChange <$> previous <*> (Update.toUpdate <$> Cbor.nested Update.decodeCbor) <*> policy
  1 -> HardForkInitiation <$> previous <*> Cbor.nested Version.decodeCbor
  2 -> TreasuryWithdrawals <$> withdrawalsDecoder <*> policy
  3 -> NoConfidence <$> previous
  4 ->
    UpdateCommittee
      <$> previous
      <*> (removalsFromList <$> Cbor.setList Cbor.credentialDecoder)
      <*> Cbor.nested Committee.decodeMembers
      <*> Cbor.nested Interval.decodeCbor
  5 -> NewConstitution <$> previous <*> Cbor.nested Constitution.decodeCbor
  6 -> pure InfoAction
  _ -> fail "Unknown governance action"
  where
    previous = Cbor.optional (Cbor.nested ActionId.decodeCbor)
    policy = Cbor.optional (D.decodeBytes >>= either (fail . show) pure . Credential.scriptHashFromBytes)

withdrawalsDecoder :: D.Decoder s Withdrawals
withdrawalsDecoder = do
  entries <- Cbor.entries $ do
    account <- D.decodeBytes >>= either (fail . show) pure . Reward.fromBytes
    (,) account <$> D.decodeWord64
  either (fail . show) pure (withdrawalsFromList entries)
