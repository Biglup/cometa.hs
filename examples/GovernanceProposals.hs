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

-- | Assemble, serialize, reload and inspect a governance proposal offline.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = case proposalWorkflow of
  Left failure -> die (show failure)
  Right imported -> do
    putStrLn ("Serialized bytes: " <> show (ByteString.length (Proposal.proposalsCbor imported)))
    putStrLn ("Proposals: " <> show (length (Proposal.toList (Proposal.toProposals imported))))

proposalWorkflow :: Either Error Proposal.EncodedProposals
proposalWorkflow = do
  -- Deterministic public fixtures, not a funded account or signing authority.
  authority <- Credential.keyHashFromBytes (ByteString.replicate 28 0)
  location <- Anchor.mkUrl "https://example.com/proposal.json"
  payloadHash <- Anchor.dataHashFromBytes (ByteString.replicate 32 1)

  let returnAccount = Reward.fromCredential Network.testnet (Credential.KeyCredential authority)
      anchor = Anchor.Anchor location payloadHash
      changes = Update.empty {Update.updateMinFeeB = Just 155381}
      action = Action.ParameterChange Nothing changes Nothing
      -- An application obtains the required deposit from current protocol parameters.
      proposal = Proposal.Proposal 100000000000 returnAccount action anchor
  Proposal.decodeProposals (Proposal.encodeProposals (Proposal.fromList [proposal]))
