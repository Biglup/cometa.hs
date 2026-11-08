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

-- | Connected ports of the staking/governance examples in Cometa.cpp
-- 824ae8e8ac9adf113d957265532ae7ea37a628a3 (Apache-2.0). Callers choose fresh
-- credentials and current chain references; every stage confirms before the next.
module Connected.Governance
  ( rewardKey,
    rewardScript,
    withdrawZero,
    drepKey,
    drepScript,
    voteKey,
    voteScript,
    donate,
    treasury,
    describeScripts,
    describeReference,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Reward as Reward
import Cometa.Credential (Credential (..), DRep, KeyHash, ScriptHash, Stake, StakePool)
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Governance.Action as Action
import Cometa.Governance.ActionId (ActionId)
import qualified Cometa.Governance.Anchor as Anchor
import Cometa.NetworkId (NetworkId)
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Provider as Provider
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Workflows.Native as Native
import qualified Workflows.NativeScripts as Scripts

-- DEFINITIONS ----------------------------------------------------------------

-- | Register, delegate stake and voting power, withdraw, then unregister.
rewardKey :: Native.Context -> Credential Stake -> KeyHash StakePool -> IO (Either Error [Transaction])
rewardKey context stake pool = runExceptT $ do
  deposit <- ExceptT (stakeDeposit context)
  ExceptT (Native.runRewardCycle context stake Nothing pool deposit)

-- | Source V2 script reward account: stake delegation without voting delegation.
rewardScript :: Native.Context -> KeyHash StakePool -> IO (Either Error [Transaction])
rewardScript context pool = runExceptT $ do
  script <- ExceptT (fmap (fmap Script.Plutus) Scripts.alwaysSucceedsV2)
  hash <- ExceptT (Script.hash script)
  deposit <- ExceptT (stakeDeposit context)
  ExceptT (Native.runRewardCycle context (ScriptCredential hash) (Just script) pool deposit)

-- | Redeemer lists the actual balanced transaction's canonical input positions.
withdrawZero :: Native.Context -> KeyHash StakePool -> IO (Either Error [Transaction])
withdrawZero context pool = runExceptT $ do
  script <- ExceptT (fmap (fmap Script.Plutus) Scripts.withdrawZero)
  hash <- ExceptT (Script.hash script)
  deposit <- ExceptT (stakeDeposit context)
  ExceptT (Native.runWithdrawZero context (ScriptCredential hash) script pool deposit)

drepKey :: Native.Context -> Credential DRep -> Credential Stake -> IO (Either Error [Transaction])
drepKey context drep stake = runExceptT $ do
  (stakeAmount, drepAmount) <- ExceptT (deposits context)
  anchor <- except representativeAnchor
  ExceptT (Native.runDRepCycle context drep Nothing drepAmount stake stakeAmount anchor)

drepScript :: Native.Context -> Utxo -> Credential Stake -> IO (Either Error [Transaction])
drepScript context reference stake = runExceptT $ do
  script <- except (governanceScript reference)
  hash <- ExceptT (Script.hash script)
  (stakeAmount, drepAmount) <- ExceptT (deposits context)
  anchor <- except representativeAnchor
  ExceptT (Native.runDRepCycle context (ScriptCredential hash) (Just script) drepAmount stake stakeAmount anchor)

voteKey :: Native.Context -> Credential DRep -> ActionId -> IO (Either Error [Transaction])
voteKey context drep action = runExceptT $ do
  (_, drepAmount) <- ExceptT (deposits context)
  anchor <- except representativeAnchor
  ExceptT (Native.runVoteCycle context drep Nothing drepAmount anchor action)

voteScript :: Native.Context -> Utxo -> ActionId -> IO (Either Error [Transaction])
voteScript context reference action = runExceptT $ do
  script <- except (governanceScript reference)
  hash <- ExceptT (Script.hash script)
  (_, drepAmount) <- ExceptT (deposits context)
  anchor <- except representativeAnchor
  ExceptT (Native.runVoteCycle context (ScriptCredential hash) (Just script) drepAmount anchor action)

-- | Donate exactly two ADA, matching donate_to_treasury_example.cpp.
donate :: Native.Context -> IO (Either Error [Transaction])
donate context = fmap (fmap pure) (Native.runDonation context 2000000)

-- | Submit a proposal, preserving the reference-script witness used by the C++
-- example. The amount is a proposed withdrawal, not an immediate transfer.
treasury :: Native.Context -> Reward.RewardAddress -> Utxo -> ScriptHash -> Word64 -> IO (Either Error [Transaction])
treasury context reward reference expectedHash amount = runExceptT $ do
  script <- except (governanceScript reference)
  actualHash <- ExceptT (Script.hash script)
  except (unless (actualHash == expectedHash) (Left (InvalidBuildingRequest "Constitution reference script hash mismatch")))
  anchor <- except treasuryAnchor
  withdrawals <- except (Action.withdrawalsFromList [(reward, amount)])
  transaction <- ExceptT (Native.runStage context (Plan.referenceInput reference <> Plan.propose reward (Action.TreasuryWithdrawals withdrawals (Just actualHash)) anchor))
  pure [transaction]

stakeDeposit :: Native.Context -> IO (Either Error Word64)
stakeDeposit context = fmap (fmap Parameters.parameterKeyDeposit) (Provider.protocolParameters (Native.provider context))

deposits :: Native.Context -> IO (Either Error (Word64, Word64))
deposits context = runExceptT $ do
  parameters <- ExceptT (Provider.protocolParameters (Native.provider context))
  drepAmount <- except (maybe (Left (InvalidBuildingRequest "DRep deposit is unavailable in the current protocol parameters")) Right (Parameters.parameterDrepDeposit parameters))
  pure (Parameters.parameterKeyDeposit parameters, drepAmount)

governanceScript :: Utxo -> Either Error Script
governanceScript reference = case Output.referenceScript (Utxo.output reference) of
  Just script@(Script.Plutus compiled) | Plutus.version compiled == Plutus.V3 -> Right script
  _ -> Left (InvalidBuildingRequest "Expected a resolved Plutus V3 governance reference script")

representativeAnchor :: Either Error Anchor.Anchor
representativeAnchor = makeAnchor "https://storage.googleapis.com/biglup/Angel_Castillo.jsonld" "26ce09df4e6f64fe5cf248968ab78f4b8a0092580c234d78f68c079c0fce34f0"

treasuryAnchor :: Either Error Anchor.Anchor
treasuryAnchor = makeAnchor "https://raw.githubusercontent.com/IntersectMBO/governance-actions/refs/heads/main/mainnet/2024-11-19-infohf/metadata.jsonld" "93106d082a93e94df5aff74f678438bae3a647dac63465fbfcde6a3058f41a1e"

makeAnchor :: Text -> Text -> Either Error Anchor.Anchor
makeAnchor url hash = Anchor.Anchor <$> Anchor.mkUrl url <*> (Blake2b.fromHex hash >>= Anchor.dataHashFromBytes . Blake2b.toBytes)

-- | Public script identities for chain-state discovery before submitting.
describeScripts :: NetworkId -> IO (Either Error [(Text, Text)])
describeScripts network = runExceptT $ do
  reward <- ExceptT (fmap (fmap Script.Plutus) Scripts.alwaysSucceedsV2)
  zero <- ExceptT (fmap (fmap Script.Plutus) Scripts.withdrawZero)
  rewardHash <- ExceptT (Script.hash reward)
  zeroHash <- ExceptT (Script.hash zero)
  pure [("reward-script", Reward.toText (Reward.fromCredential network (ScriptCredential rewardHash))), ("withdraw-zero-script", Reward.toText (Reward.fromCredential network (ScriptCredential zeroHash)))]

-- | The reference script's DRep hash, without wallet or encrypted storage bytes.
describeReference :: Utxo -> IO (Either Error [(Text, Text)])
describeReference reference = runExceptT $ do
  script <- except (governanceScript reference)
  hash <- ExceptT (Script.hash script)
  digest <- except (Blake2b.fromBytes (Credential.scriptHashBytes hash))
  pure [("drep-script-hash", Blake2b.toHex digest)]
