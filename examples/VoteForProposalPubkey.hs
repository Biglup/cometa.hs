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
import qualified Cometa.TransactionId as Id
-- Standard library and error handling.
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Text (Text)
import Data.Word (Word64)
-- Shared example setup.
import qualified Support.Inputs as Inputs
import qualified Support.Transaction as Workflow
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypointWithDescription "VoteForProposalPubkey" (Inputs.describe Nothing) $ \wallet -> runExceptT $ do
  let context = Support.context wallet
  action <- ExceptT Inputs.actionId
  ExceptT (voteKey context (Support.drepCredential wallet) action)

-- | Register a fresh DRep, vote on the supplied action, then reclaim its deposit.
voteKey :: Workflow.Context -> Credential DRep -> ActionId -> IO (Either Error [Transaction])
voteKey context drep action = runExceptT $ do
  (_, drepAmount) <- ExceptT (deposits context)
  anchor <- except representativeAnchor

  let certify = Plan.certificate

  registered <- submitPlan context (certify (Certificate.RegisterDRep drep drepAmount (Just anchor)))

  let voter = Voting.DRepVoter drep
      procedure = Voting.VotingProcedure Voting.Yes Nothing
      vote = Plan.vote voter action procedure

  voted <- submitPlan context vote

  cleaned <- submitPlan context (certify (Certificate.UnregisterDRep drep drepAmount))

  pure [registered, voted, cleaned]

deposits :: Workflow.Context -> IO (Either Error (Word64, Word64))
deposits context = runExceptT $ do
  parameters <- ExceptT (Provider.protocolParameters (Workflow.provider context))
  drepAmount <- case Parameters.parameterDrepDeposit parameters of
    Just amount -> pure amount
    Nothing -> throwE (InvalidBuildingRequest "DRep deposit is unavailable in the current protocol parameters")
  pure (Parameters.parameterKeyDeposit parameters, drepAmount)

representativeAnchor :: Either Error Anchor.Anchor
representativeAnchor =
  makeAnchor
    "https://storage.googleapis.com/biglup/Angel_Castillo.jsonld"
    "26ce09df4e6f64fe5cf248968ab78f4b8a0092580c234d78f68c079c0fce34f0"

makeAnchor :: Text -> Text -> Either Error Anchor.Anchor
makeAnchor url hash = Anchor.Anchor <$> Anchor.mkUrl url <*> (Blake2b.fromHex hash >>= Anchor.dataHashFromBytes . Blake2b.toBytes)

-- | Run one stage; dependent stages start only after confirmation and indexing.
submitPlan :: Workflow.Context -> Plan.Plan -> ExceptT Error IO Tx.Transaction
submitPlan ctx plan = do
  unsignedTx <- buildTransaction ctx plan
  signedTx <- signTransaction ctx unsignedTx

  txId <- submitTransaction ctx signedTx
  awaitConfirmation ctx signedTx txId

  pure signedTx

-- | Fetch current wallet inputs and parameters, then apply the configured expiry.
buildTransaction :: Workflow.Context -> Plan.Plan -> ExceptT Error IO Tx.Transaction
buildTransaction ctx plan = do
  settings <- ExceptT (Workflow.builderConfig ctx)
  ExceptT $
    Builder.build settings (plan <> Plan.validUntil (Workflow.invalidAfter ctx))

-- | The scoped wallet requests its password and supplies the required witnesses.
signTransaction :: Workflow.Context -> Tx.Transaction -> ExceptT Error IO Tx.Transaction
signTransaction ctx unsignedTx = do
  witnesses <-
    ExceptT (Signer.signTransaction (Workflow.signer ctx) unsignedTx)
  except (Tx.addWitnesses witnesses unsignedTx)

-- | Submit once and verify the provider accepted this exact transaction body.
submitTransaction :: Workflow.Context -> Tx.Transaction -> ExceptT Error IO Id.TransactionId
submitTransaction ctx signedTx = do
  expected <- ExceptT (Tx.transactionId signedTx)
  accepted <- ExceptT (Provider.submitTransaction (Workflow.provider ctx) signedTx)

  unless (accepted == expected) $
    throwE (InvalidProviderResponse "Submitted transaction ID mismatch")

  pure accepted

-- | Stop on timeout; wait for the wallet index before spending dependent outputs.
awaitConfirmation :: Workflow.Context -> Tx.Transaction -> Id.TransactionId -> ExceptT Error IO ()
awaitConfirmation ctx signedTx txId = do
  confirmed <-
    ExceptT $
      Provider.awaitTransaction
        (Workflow.provider ctx)
        txId
        (Workflow.confirmationTimeoutMillis ctx)

  unless confirmed $
    throwE (InvalidBuildingRequest "Transaction confirmation timed out")

  ExceptT (Workflow.awaitWallet ctx signedTx)
