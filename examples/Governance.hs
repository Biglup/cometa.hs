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

-- | Build, serialize and reload a role-aware DRep vote with an explanation.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.TransactionId as TransactionId
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT prepareVote
  case result of
    Left failure -> die (show failure)
    Right (original, reloaded) -> do
      putStrLn ("Voting pairs: " <> show (length (Voting.toList (Voting.toVotingProcedures reloaded))))
      putStrLn ("Exact stored bytes retained: " <> show (original == Voting.toCbor reloaded))

prepareVote :: ExceptT Error IO (ByteString.ByteString, Voting.EncodedVotingProcedures)
prepareVote = do
  -- Demonstration identities only; replace these with runtime application input.
  key <- except (Credential.keyHashFromBytes (ByteString.replicate 28 1))
  transaction <- except (TransactionId.fromBytes (ByteString.replicate 32 2))
  location <- except (Anchor.mkUrl "https://example.com/vote.json")
  digest <- ExceptT (Anchor.hashData "{\"comment\":\"Support this proposal\"}")

  let voter = Voting.DRepVoter (Credential.KeyCredential key)
      action = ActionId.ActionId transaction 0
      explanation = Anchor.Anchor location digest
      procedure = Voting.VotingProcedure Voting.Yes (Just explanation)
      votes = Voting.singleton voter action procedure
      storedBytes = Voting.encodeCbor votes

  -- Read the same bytes from storage into this decoder in a real application.
  -- toCbor retains them exactly, even for accepted nonminimal external encodings.
  reloaded <- except (Voting.decodeCbor storedBytes)
  pure (storedBytes, reloaded)
