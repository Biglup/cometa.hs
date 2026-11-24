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

module Support.Inputs (poolId, actionId, treasurySettings, describe) where

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.TransactionId as TransactionId
-- Standard library and error handling.
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
-- Shared example setup.
import qualified Support.Governance as Governance
import qualified Support.Transaction as Native
import qualified Support.Wallet as Support

poolId :: IO (Either Error (Credential.KeyHash Credential.StakePool))
poolId = do
  value <- Support.required "COMETA_POOL_ID_HEX"
  pure (value >>= Blake2b.fromHex >>= Credential.keyHashFromBytes . Blake2b.toBytes)

actionId :: IO (Either Error ActionId.ActionId)
actionId = do
  value <- Support.required "COMETA_GOVERNANCE_ACTION"
  pure $ do
    text <- value
    case Text.splitOn "#" text of
      [transaction, index] -> ActionId.ActionId <$> TransactionId.fromHex transaction <*> Support.unsigned index
      _ -> Left (InvalidBuildingRequest "COMETA_GOVERNANCE_ACTION must be TXID#INDEX")

treasurySettings :: IO (Either Error (Reward.RewardAddress, Credential.ScriptHash, Word64))
treasurySettings = do
  hash <- Support.required "COMETA_CONSTITUTION_SCRIPT_HASH"
  amount <- Support.required "COMETA_TREASURY_WITHDRAWAL_LOVELACE"
  reward <- Support.required "COMETA_TREASURY_RETURN_ACCOUNT"
  pure $ do
    parsedHash <- hash >>= Blake2b.fromHex >>= Credential.scriptHashFromBytes . Blake2b.toBytes
    parsedAmount <- amount >>= Support.unsigned
    parsedReward <- reward >>= Reward.fromText
    pure (parsedReward, parsedHash, parsedAmount)

describe :: Maybe String -> Support.WalletContext -> IO (Either Error [(Text, Text)])
describe referenceName wallet = runExceptT $ do
  let context = Support.context wallet
  identities <- ExceptT (Governance.describeScripts (Native.network context))
  case referenceName of
    Nothing -> pure identities
    Just name -> do
      reference <- ExceptT (Support.resolveReference context name)
      additional <- ExceptT (Governance.describeReference reference)
      pure (identities <> additional)
