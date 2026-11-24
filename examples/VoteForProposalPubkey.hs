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

module VoteForProposalPubkey (main, voteKey) where

import qualified Cometa.Certificate as Certificate
import Cometa.Credential (Credential (..), DRep)
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import Cometa.Governance.ActionId (ActionId)
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Plan as Plan
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Support.Inputs as Inputs
import qualified Support.Transaction as Workflow
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypointWithDescription "VoteForProposalPubkey" (Inputs.describe Nothing) $ \wallet -> runExceptT $ do
  let context = Support.context wallet
  action <- ExceptT Inputs.actionId
  ExceptT (voteKey context (Support.drepCredential wallet) action)

voteKey :: Workflow.Context -> Credential DRep -> ActionId -> IO (Either Error [Transaction])
voteKey context drep action = runExceptT $ do
  (_, drepAmount) <- ExceptT (deposits context)
  anchor <- except representativeAnchor
  let certify = Plan.certificate
  registered <- ExceptT (submitPlan context (certify (Certificate.RegisterDRep drep drepAmount (Just anchor))))
  let voter = Voting.DRepVoter drep
      procedure = Voting.VotingProcedure Voting.Yes Nothing
      vote = Plan.vote voter action procedure
  voted <- ExceptT (submitPlan context vote)
  cleaned <- ExceptT (submitPlan context (certify (Certificate.UnregisterDRep drep drepAmount)))
  pure [registered, voted, cleaned]

deposits :: Workflow.Context -> IO (Either Error (Word64, Word64))
deposits context = runExceptT $ do
  parameters <- ExceptT (Provider.protocolParameters (Workflow.provider context))
  drepAmount <- except (maybe (Left (InvalidBuildingRequest "DRep deposit is unavailable in the current protocol parameters")) Right (Parameters.parameterDrepDeposit parameters))
  pure (Parameters.parameterKeyDeposit parameters, drepAmount)

representativeAnchor :: Either Error Anchor.Anchor
representativeAnchor = makeAnchor "https://storage.googleapis.com/biglup/Angel_Castillo.jsonld" "26ce09df4e6f64fe5cf248968ab78f4b8a0092580c234d78f68c079c0fce34f0"

makeAnchor :: Text -> Text -> Either Error Anchor.Anchor
makeAnchor url hash = Anchor.Anchor <$> Anchor.mkUrl url <*> (Blake2b.fromHex hash >>= Anchor.dataHashFromBytes . Blake2b.toBytes)

submitPlan :: Workflow.Context -> Plan.Plan -> IO (Either Error Tx.Transaction)
submitPlan ctx plan = runExceptT $ do
  settings <- ExceptT (Workflow.builderConfig ctx)
  unsigned <- ExceptT (Builder.build settings (plan <> Plan.validUntil (Workflow.invalidAfter ctx)))
  witnesses <- ExceptT (Signer.signTransaction (Workflow.signer ctx) unsigned)
  signed <- except (Tx.addWitnesses witnesses unsigned)
  expected <- ExceptT (Tx.transactionId signed)
  accepted <- ExceptT (Provider.submitTransaction (Workflow.provider ctx) signed)
  unless (accepted == expected) (throwE (InvalidProviderResponse "Submitted transaction ID mismatch"))
  confirmed <- ExceptT (Provider.awaitTransaction (Workflow.provider ctx) accepted (Workflow.confirmationTimeoutMillis ctx))
  unless confirmed (throwE (InvalidBuildingRequest "Transaction confirmation timed out"))
  ExceptT (Workflow.awaitWallet ctx signed)
  pure signed
