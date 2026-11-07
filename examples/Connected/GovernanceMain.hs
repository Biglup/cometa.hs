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

-- | Environment assembly for the connected staking/governance example runners.
module Connected.GovernanceMain (Flow (..), mainFor) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.TransactionId as TransactionId
import qualified Connected.Governance as Governance
import qualified Connected.Support as Support
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.Text as Text
import qualified Workflows.Native as Native

-- TYPES ----------------------------------------------------------------------

data Flow = RewardKey | RewardScript | DRepKey | DRepScript | VoteKey | VoteScript | Donation | Treasury | WithdrawZero

-- DEFINITIONS ----------------------------------------------------------------

mainFor :: Flow -> IO ()
mainFor flow = Support.entrypointWithDescription (flowName flow) describe run
  where
    describe wallet = runExceptT $ do
      identities <- ExceptT (Governance.describeScripts (Native.network (Support.context wallet)))
      case referenceName flow of
        Nothing -> pure identities
        Just name -> do
          reference <- ExceptT (Support.resolveReference (Support.context wallet) name)
          additional <- ExceptT (Governance.describeReference reference)
          pure (identities <> additional)
    run wallet = runExceptT $ do
      let context = Support.context wallet
          stake = Support.stakeCredential wallet
          drep = Support.drepCredential wallet
      case flow of
        RewardKey -> do
          pool <- ExceptT poolId
          ExceptT (Governance.rewardKey context stake pool)
        RewardScript -> do
          pool <- ExceptT poolId
          ExceptT (Governance.rewardScript context pool)
        WithdrawZero -> do
          pool <- ExceptT poolId
          ExceptT (Governance.withdrawZero context pool)
        DRepKey -> ExceptT (Governance.drepKey context drep stake)
        DRepScript -> do
          reference <- ExceptT (Support.resolveReference context "COMETA_GOVERNANCE_REFERENCE")
          ExceptT (Governance.drepScript context reference stake)
        VoteKey -> do
          action <- ExceptT actionId
          ExceptT (Governance.voteKey context drep action)
        VoteScript -> do
          reference <- ExceptT (Support.resolveReference context "COMETA_GOVERNANCE_REFERENCE")
          action <- ExceptT actionId
          ExceptT (Governance.voteScript context reference action)
        Donation -> ExceptT (Governance.donate context)
        Treasury -> do
          reference <- ExceptT (Support.resolveReference context "COMETA_CONSTITUTION_REFERENCE")
          hashText <- ExceptT (Support.required "COMETA_CONSTITUTION_SCRIPT_HASH")
          hash <- except (Blake2b.fromHex hashText >>= Credential.scriptHashFromBytes . Blake2b.toBytes)
          amountText <- ExceptT (Support.required "COMETA_TREASURY_WITHDRAWAL_LOVELACE")
          amount <- except (Support.unsigned amountText)
          rewardText <- ExceptT (Support.required "COMETA_TREASURY_RETURN_ACCOUNT")
          reward <- except (Reward.fromText rewardText)
          ExceptT (Governance.treasury context reward reference hash amount)

poolId :: IO (Either Error (Credential.KeyHash Credential.StakePool))
poolId = runExceptT $ do
  text <- ExceptT (Support.required "COMETA_POOL_ID_HEX")
  except (Blake2b.fromHex text >>= Credential.keyHashFromBytes . Blake2b.toBytes)

actionId :: IO (Either Error ActionId.ActionId)
actionId = runExceptT $ do
  text <- ExceptT (Support.required "COMETA_GOVERNANCE_ACTION")
  except $ case Text.splitOn "#" text of
    [transaction, index] -> ActionId.ActionId <$> TransactionId.fromHex transaction <*> Support.unsigned index
    _ -> Left (InvalidBuildingRequest "COMETA_GOVERNANCE_ACTION must be TXID#INDEX")

referenceName :: Flow -> Maybe String
referenceName flow = case flow of
  DRepScript -> Just "COMETA_GOVERNANCE_REFERENCE"
  VoteScript -> Just "COMETA_GOVERNANCE_REFERENCE"
  Treasury -> Just "COMETA_CONSTITUTION_REFERENCE"
  _ -> Nothing

flowName :: Flow -> String
flowName flow = case flow of
  RewardKey -> "reward-account-pubkey"
  RewardScript -> "reward-account-script"
  DRepKey -> "drep-pubkey"
  DRepScript -> "drep-script"
  VoteKey -> "vote-for-proposal-pubkey"
  VoteScript -> "vote-for-proposal-script"
  Donation -> "donate-to-treasury"
  Treasury -> "propose-treasury-withdrawal"
  WithdrawZero -> "deferred-withdraw-zero"
