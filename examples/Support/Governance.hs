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

-- | Public script identities for inspecting configured governance examples.
module Support.Governance (describeScripts, describeReference) where

import qualified Cometa.Address.Reward as Reward
import Cometa.Credential (Credential (..))
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import Cometa.NetworkId (NetworkId)
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Text (Text)
import qualified Support.Scripts as Scripts

governanceScript :: Utxo -> Either Error Script
governanceScript reference = case Output.referenceScript (Utxo.output reference) of
  Just script@(Script.Plutus compiled) | Plutus.version compiled == Plutus.V3 -> Right script
  _ -> Left (InvalidBuildingRequest "Expected a resolved Plutus V3 governance reference script")

describeScripts :: NetworkId -> IO (Either Error [(Text, Text)])
describeScripts network = runExceptT $ do
  reward <- ExceptT (fmap (fmap Script.Plutus) Scripts.alwaysSucceedsV2)
  zero <- ExceptT (fmap (fmap Script.Plutus) Scripts.withdrawZero)
  rewardHash <- ExceptT (Script.hash reward)
  zeroHash <- ExceptT (Script.hash zero)
  pure [("reward-script", Reward.toText (Reward.fromCredential network (ScriptCredential rewardHash))), ("withdraw-zero-script", Reward.toText (Reward.fromCredential network (ScriptCredential zeroHash)))]

describeReference :: Utxo -> IO (Either Error [(Text, Text)])
describeReference reference = runExceptT $ do
  script <- except (governanceScript reference)
  hash <- ExceptT (Script.hash script)
  digest <- except (Blake2b.fromBytes (Credential.scriptHashBytes hash))
  pure [("drep-script-hash", Blake2b.toHex digest)]
