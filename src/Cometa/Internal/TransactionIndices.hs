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
{-# OPTIONS_HADDOCK hide #-}

-- | Level-local index inspection shared by top-level and nested transactions.
module Cometa.Internal.TransactionIndices
  ( findInput,
    findReferenceInput,
    findOutput,
    findMintPolicy,
    findWithdrawal,
    findVote,
    findRedeemer,
    certificateBytes,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Term as T
import Cometa.Address (Address)
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import Cometa.AssetId (AssetId (Ada))
import qualified Cometa.Credential as Credential
import Cometa.Evaluation (RedeemerId (..))
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.NetworkId as Network
import Cometa.PolicyId (PolicyId)
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Transaction.Fields as Fields
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Value as Value
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Word (Word64)

-- DEFINITIONS ----------------------------------------------------------------

findInput :: Input -> Fields.Fields -> Maybe Word64
findInput reference = position (== reference) . sort . Fields.fieldInputs

findReferenceInput :: Input -> Fields.Fields -> Maybe Word64
findReferenceInput reference = position (== reference) . sort . fromMaybe [] . Fields.fieldReferenceInputs

findOutput :: Address -> Word64 -> Fields.Fields -> Maybe Word64
findOutput destination minimumLovelace = position matches . Fields.fieldOutputs
  where
    matches output =
      Address.toBytes (Output.address output) == Address.toBytes destination
        && Value.quantity Ada (Output.value output) >= toInteger minimumLovelace

findMintPolicy :: PolicyId -> ByteString -> Maybe Word64
findMintPolicy policy bytes = do
  mint <- fieldBytes 9 bytes
  policies <- either (const Nothing) Just (Cbor.decode (Cbor.entries (D.decodeBytes <* T.decodeTerm)) mint)
  position (== Policy.toBytes policy) (sort policies)

-- Ledger ordering groups non-mainnet tags together and puts scripts first.
findWithdrawal :: Reward.RewardAddress -> Fields.Fields -> Maybe Word64
findWithdrawal reward = rank (rewardKey reward) . map (rewardKey . fst) . maybe [] Fields.entries . Fields.fieldWithdrawals

rewardKey :: Reward.RewardAddress -> ByteString
rewardKey reward = B.cons (if Reward.networkId reward == Network.mainnet then 1 else 0) (credentialKey (Reward.credential reward))

credentialKey :: Credential.Credential purpose -> ByteString
credentialKey authority = case authority of
  Credential.ScriptCredential hash -> B.cons 0 (Credential.scriptHashBytes hash)
  Credential.KeyCredential hash -> B.cons 1 (Credential.keyHashBytes hash)

findVote :: Voting.Voter -> Fields.Fields -> Maybe Word64
findVote voter = rank (voterKey voter) . map voterKey . Set.toList . Set.fromList . map (\(authority, _, _) -> authority) . maybe [] Voting.toList . Fields.fieldVotingProcedures

voterKey :: Voting.Voter -> ByteString
voterKey voter = case voter of
  Voting.CommitteeVoter authority -> B.cons 0 (credentialKey authority)
  Voting.DRepVoter authority -> B.cons 1 (credentialKey authority)
  Voting.StakePoolVoter hash -> B.cons 2 (B.cons 1 (Credential.keyHashBytes hash))

findRedeemer :: RedeemerId -> [Redeemer.Redeemer] -> Maybe Word64
findRedeemer identifier = rank identifier . map (\value -> RedeemerId (Redeemer.purpose value) (Redeemer.index value))

certificateBytes :: ByteString -> Maybe ByteString
certificateBytes = fieldBytes 4

fieldBytes :: Word64 -> ByteString -> Maybe ByteString
fieldBytes key bytes = do
  fields <- either (const Nothing) Just (Cbor.decode (Cbor.mapFields bytes) bytes)
  Map.lookup key fields

-- Native lookups count items strictly below the requested ledger key.
rank :: (Ord a) => a -> [a] -> Maybe Word64
rank target values
  | target `elem` values = Just (fromIntegral (length (filter (< target) values)))
  | otherwise = Nothing

position :: (a -> Bool) -> [a] -> Maybe Word64
position matches = go 0
  where
    go _ [] = Nothing
    go index (value : rest)
      | matches value = Just index
      | otherwise = go (index + 1) rest
