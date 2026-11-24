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

module DRepScript (main, drepScript) where

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Certificate as Certificate
import Cometa.Credential (Credential (..), Stake)
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Provider as Provider
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Signer as Signer
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
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
main = Support.entrypointWithDescription "DRepScript" (Inputs.describe (Just "COMETA_GOVERNANCE_REFERENCE")) $ \wallet -> runExceptT $ do
  let context = Support.context wallet
  reference <- ExceptT (Support.resolveReference context "COMETA_GOVERNANCE_REFERENCE")
  ExceptT (drepScript context reference (Support.stakeCredential wallet))

-- | Use the configured V3 script as the DRep authority for registration and cleanup.
drepScript :: Workflow.Context -> Utxo -> Credential Stake -> IO (Either Error [Transaction])
drepScript context reference stake = runExceptT $ do
  script <- except (governanceScript reference)
  hash <- ExceptT (Script.hash script)
  (stakeAmount, drepAmount) <- ExceptT (deposits context)
  anchor <- except representativeAnchor

  let drep = ScriptCredential hash
      certify certificate = Plan.attachScript script <> Plan.certificateWithRedeemer certificate voidArgument

  registered <- submitPlan context (certify (Certificate.RegisterDRep drep drepAmount (Just anchor)))

  let delegation =
        Plan.certificate (Certificate.Registration stake stakeAmount)
          <> Plan.certificate (Certificate.VoteDelegation stake (DRep.DRepCredential drep))

  delegated <- submitPlan context delegation

  let account = Reward.fromCredential (Workflow.network context) stake
  rewards <- ExceptT (Provider.rewardBalance (Workflow.provider context) account)

  cleanedStake <- submitPlan context (Plan.withdraw account rewards <> Plan.certificate (Certificate.Unregistration stake stakeAmount))

  cleanedDRep <- submitPlan context (certify (Certificate.UnregisterDRep drep drepAmount))

  pure [registered, delegated, cleanedStake, cleanedDRep]

deposits :: Workflow.Context -> IO (Either Error (Word64, Word64))
deposits context = runExceptT $ do
  parameters <- ExceptT (Provider.protocolParameters (Workflow.provider context))
  drepAmount <- case Parameters.parameterDrepDeposit parameters of
    Just amount -> pure amount
    Nothing -> throwE (InvalidBuildingRequest "DRep deposit is unavailable in the current protocol parameters")
  pure (Parameters.parameterKeyDeposit parameters, drepAmount)

governanceScript :: Utxo -> Either Error Script
governanceScript reference = case Output.referenceScript (Utxo.output reference) of
  Just script@(Script.Plutus compiled) | Plutus.version compiled == Plutus.V3 -> Right script
  _ -> Left (InvalidBuildingRequest "Expected a resolved Plutus V3 governance reference script")

representativeAnchor :: Either Error Anchor.Anchor
representativeAnchor =
  makeAnchor
    "https://storage.googleapis.com/biglup/Angel_Castillo.jsonld"
    "26ce09df4e6f64fe5cf248968ab78f4b8a0092580c234d78f68c079c0fce34f0"

makeAnchor :: Text -> Text -> Either Error Anchor.Anchor
makeAnchor url hash = Anchor.Anchor <$> Anchor.mkUrl url <*> (Blake2b.fromHex hash >>= Anchor.dataHashFromBytes . Blake2b.toBytes)

voidArgument :: Data.EncodedPlutusData
voidArgument = Data.fromData (Data.Constr 0 [])

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
