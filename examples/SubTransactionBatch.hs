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

-- | Buyer and seller sign local intents; a third encrypted wallet submits the batch.
module Main (main) where

import Cometa.AssetId (AssetId (Native))
import qualified Cometa.AssetName as AssetName
import Cometa.Credential (Credential (..), Guard)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.NetworkId as Network
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Builder as SubBuilder
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
-- Standard library and error handling.
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import qualified Data.Text as Text
-- Shared example setup.
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext)
import qualified Support.Wallet as Wallet

main :: IO ()
main = Wallet.entrypoint "SubTransactionBatch" batch

batch :: WalletContext -> IO (Either Error Tx.Transaction)
batch batcher = runExceptT $ do
  params <- ExceptT (Provider.protocolParameters (Workflow.provider (Wallet.context batcher)))

  let Version.ProtocolVersion major _ = Parameters.parameterProtocolVersion params
  unless
    (major >= 12)
    (throwE (UnsupportedOperation "Subtransaction batches require protocol 12 or later"))
  buyerFile <- ExceptT (Wallet.required "COMETA_BUYER_WALLET")
  sellerFile <- ExceptT (Wallet.required "COMETA_SELLER_WALLET")
  ExceptT $ Wallet.withWalletFile (Text.unpack buyerFile) $ \buyer ->
    Wallet.withWalletFile (Text.unpack sellerFile) $ \seller -> runExceptT $ do
      let addresses = map (Workflow.wallet . Wallet.context) [buyer, seller, batcher]
      unless
        (and [a /= b | (a, b) <- zip addresses (drop 1 addresses <> take 1 addresses)])
        (throwE (InvalidBuildingRequest "Buyer, seller and batcher must have distinct addresses"))
      policy <- ExceptT (Wallet.required "COMETA_SWAP_POLICY") >>= except . Policy.fromHex
      name <- ExceptT (Wallet.required "COMETA_SWAP_ASSET_NAME") >>= except . AssetName.fromHex

      let token = Native policy name
      buyerInput <- ExceptT (Wallet.resolveReference (Wallet.context buyer) "COMETA_BUYER_INPUT")
      sellerInput <- ExceptT (Wallet.resolveReference (Wallet.context seller) "COMETA_SELLER_INPUT")
      guard <- except $ case Wallet.paymentCredential batcher of
        Credential.KeyCredential hash -> Credential.KeyCredential <$> Credential.keyHashFromBytes (Credential.keyHashBytes hash)
        _ -> Left (InvalidBuildingRequest "The batcher must use a payment key")
      buyerIntent <-
        ExceptT $
          signedIntent
            params
            guard
            buyer
            buyerInput
            (Value.lovelace 100000000)
            (Value.lovelace 50000000 <> Value.singleton token 1000)
      sellerIntent <-
        ExceptT $
          signedIntent
            params
            guard
            seller
            sellerInput
            (Value.lovelace 10000000 <> Value.singleton token 5000)
            (Value.lovelace 60000000 <> Value.singleton token 4000)

      let batchPlan =
            Plan.attachSubTransaction buyerIntent [buyerInput]
              <> Plan.attachSubTransaction sellerIntent [sellerInput]
              <> Plan.requireGuard guard

      submitPlan (Wallet.context batcher) batchPlan

-- | Check the party owns the exact input value, then sign its guarded swap intent.
signedIntent ::
  Parameters.Parameters ->
  Credential Guard ->
  WalletContext ->
  Utxo.Utxo ->
  Value.Value ->
  Value.Value ->
  IO (Either Error Sub.SubTransaction)
signedIntent params guard wallet input expected payout = runExceptT $ do
  let ctx = Wallet.context wallet
      network = if Workflow.network ctx == Network.mainnet then Fields.Mainnet else Fields.Testnet
  unless
    (Output.address (Utxo.output input) == Workflow.wallet ctx && Output.value (Utxo.output input) == expected)
    (throwE (InvalidBuildingRequest "Swap input must belong to its wallet and contain exactly the documented coin/token amounts"))
  output <- except (Output.mkOutput (Workflow.wallet ctx) payout Datum.NoDatum Nothing)

  let plan = SubPlan.spend input <> SubPlan.payTo output <> SubPlan.requireTopLevelGuard guard Nothing
  unsigned <- ExceptT (SubBuilder.build (SubBuilder.Config params (Workflow.slots ctx) network) plan)
  ExceptT (Wallet.signSubTransaction wallet unsigned)

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
