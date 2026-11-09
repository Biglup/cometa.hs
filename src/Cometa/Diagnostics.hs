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

-- | Human-readable category labels for logs and error messages. Unlike 'Show',
-- these functions describe only the category and never include hashes, keys or
-- payloads. They use the English cardano-c diagnostic vocabulary, not CIP-116
-- JSON tags. Use the domain encoders for machine interchange.
module Cometa.Diagnostics (certificateKind, nativeScriptKind, vote, voterKind) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Certificate as Certificate
import qualified Cometa.Credential as Credential
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Script.Native as Native
import Data.Text (Text)

-- DEFINITIONS ----------------------------------------------------------------

-- | Certificate category, for example @"Certificate Type: Stake Registration"@.
-- Field contents and registration/deposit state do not affect the label.
certificateKind :: Certificate.Certificate -> Text
certificateKind value = case value of
  Certificate.StakeRegistration {} -> "Certificate Type: Stake Registration"
  Certificate.StakeDeregistration {} -> "Certificate Type: Stake Deregistration"
  Certificate.StakeDelegation {} -> "Certificate Type: Stake Delegation"
  Certificate.PoolRegistration {} -> "Certificate Type: Pool Registration"
  Certificate.PoolRetirement {} -> "Certificate Type: Pool Retirement"
  Certificate.GenesisKeyDelegation {} -> "Certificate Type: Genesis Key Delegation"
  Certificate.MoveInstantaneousRewards {} -> "Certificate Type: Move Instantaneous Rewards"
  Certificate.Registration {} -> "Certificate Type: Registration"
  Certificate.Unregistration {} -> "Certificate Type: Unregistration"
  Certificate.VoteDelegation {} -> "Certificate Type: Vote Delegation"
  Certificate.StakeVoteDelegation {} -> "Certificate Type: Stake Vote Delegation"
  Certificate.StakeRegistrationDelegation {} -> "Certificate Type: Stake Registration Delegation"
  Certificate.VoteRegistrationDelegation {} -> "Certificate Type: Vote Registration Delegation"
  Certificate.StakeVoteRegistrationDelegation {} -> "Certificate Type: Stake Vote Registration Delegation"
  Certificate.AuthorizeCommitteeHot {} -> "Certificate Type: Auth Committee Hot"
  Certificate.ResignCommitteeCold {} -> "Certificate Type: Resign Committee Cold"
  Certificate.RegisterDRep {} -> "Certificate Type: DRep Registration"
  Certificate.UnregisterDRep {} -> "Certificate Type: DRep Unregistration"
  Certificate.UpdateDRep {} -> "Certificate Type: Update DRep"

-- | Native script condition, for example @"Native Script Type: Require All Of"@.
-- Does not evaluate the script or expose any child condition or credential.
nativeScriptKind :: Native.NativeScript -> Text
nativeScriptKind value = case Native.view value of
  Native.RequireSignature {} -> "Native Script Type: Require Pubkey"
  Native.RequireAll {} -> "Native Script Type: Require All Of"
  Native.RequireAny {} -> "Native Script Type: Require Any Of"
  Native.RequireAtLeast {} -> "Native Script Type: Require N Of K"
  Native.InvalidBefore {} -> "Native Script Type: Invalid Before"
  Native.InvalidAfter {} -> "Native Script Type: Invalid After"
  Native.RequireGuard {} -> "Native Script Type: Require Guard"

-- | Voting choice as @"Vote: No"@, @"Vote: Yes"@ or @"Vote: Abstain"@.
vote :: Voting.Vote -> Text
vote value = case value of
  Voting.No -> "Vote: No"
  Voting.Yes -> "Vote: Yes"
  Voting.Abstain -> "Vote: Abstain"

-- | Voting authority kind, distinguishing committee and DRep key/script
-- credentials from stake pool keys. The credential hash is never included.
voterKind :: Voting.Voter -> Text
voterKind value = case value of
  Voting.CommitteeVoter (Credential.KeyCredential _) -> "Voter Type: Constitutional Committee Key Hash"
  Voting.CommitteeVoter (Credential.ScriptCredential _) -> "Voter Type: Constitutional Committee Script Hash"
  Voting.DRepVoter (Credential.KeyCredential _) -> "Voter Type: DRep Key Hash"
  Voting.DRepVoter (Credential.ScriptCredential _) -> "Voter Type: DRep Script Hash"
  Voting.StakePoolVoter _ -> "Voter Type: Stake Pool Key Hash"
