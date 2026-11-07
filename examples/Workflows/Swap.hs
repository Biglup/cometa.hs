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

-- | Port of cardano-c examples/src/sub_transaction_batch_example.c at
-- eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1 (Apache-2.0): buyer and seller sign
-- independent token/coin intents; a third party funds and signs their batch.
module Workflows.Swap (Swap (..), runSwap) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Address (Address)
import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import Cometa.AssetId (AssetId (Native))
import qualified Cometa.AssetName as AssetName
import Cometa.Credential (Credential, Guard)
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error (..))
import qualified Cometa.NetworkId as Network
import qualified Cometa.PolicyId as Policy
import Cometa.Protocol.Parameters (Parameters)
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.SlotConfig as Slots
import Cometa.SubTransaction (SubTransaction)
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Builder as SubBuilder
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Signing as Signing
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import Data.Word (Word8)
import qualified Fixtures.ProtocolParameters as Fixture

-- TYPES ----------------------------------------------------------------------

data Swap = Swap
  { transaction :: Tx.Transaction,
    buyerIntent :: SubTransaction,
    sellerIntent :: SubTransaction,
    resolvedInputs :: [Utxo]
  }

data Party = Party Address (Credential Guard) Utxo Key.SigningKey

-- DEFINITIONS ----------------------------------------------------------------

runSwap :: IO (Either Error Swap)
runSwap = runExceptT $ do
  raw <- except Fixture.parameters
  policy <- except (Policy.fromHex "1ec85dcee27f2d90ec1f9a1e4ce74a667dc9be8b184463223f9c9601")
  name <- except (AssetName.fromHex "54534c41")
  let token = Native policy name
      params =
        raw
          { Parameters.parameterMinFeeA = 44,
            Parameters.parameterMinFeeB = 155381,
            Parameters.parameterMaxTxSize = 16384,
            Parameters.parameterMaxValueSize = Just 5000,
            Parameters.parameterAdaPerUtxoByte = Just 4310,
            Parameters.parameterProtocolVersion = Version.ProtocolVersion 12 0
          }
  ExceptT $ withParty token 1 100000000 0 $ \buyer ->
    withParty token 2 10000000 5000 $ \seller ->
      withParty token 3 20000000 0 $ \batcher ->
        settle params token buyer seller batcher

-- Public demonstration seeds and synthetic UTxOs only; never fund these keys.
withParty :: AssetId -> Word8 -> Integer -> Integer -> (Party -> IO (Either Error a)) -> IO (Either Error a)
withParty token seed coin tokens action = Key.withNormalKey (B.replicate 32 seed) $ \key -> do
  prepared <- runExceptT $ do
    public <- ExceptT (Key.publicKey key)
    payment <- ExceptT (Credential.fromPublicKey public)
    guard <- ExceptT (Credential.fromPublicKey public)
    previous <- except (Id.fromBytes (B.replicate 32 seed))
    let address = Address.ShelleyAddress (Shelley.enterprise Network.testnet payment)
        value = Value.lovelace coin <> Value.singleton token tokens
    output <- except (Output.mkOutput address value Datum.NoDatum Nothing)
    pure (Party address guard (Utxo.utxo (Input.input previous 0) output) key)
  either (pure . Left) action prepared

signedIntent :: Parameters -> AssetId -> Credential Guard -> Party -> Integer -> Integer -> IO (Either Error SubTransaction)
signedIntent params token batcherGuard (Party address _ input key) coin tokens = runExceptT $ do
  output <- except (Output.mkOutput address (Value.lovelace coin <> Value.singleton token tokens) Datum.NoDatum Nothing)
  let plan = SubPlan.spend input <> SubPlan.payTo output <> SubPlan.requireTopLevelGuard batcherGuard Nothing
  local <- ExceptT (SubBuilder.build (SubBuilder.Config params Slots.preprod Fields.Testnet) plan)
  identifier <- ExceptT (Sub.transactionId local)
  signed <- ExceptT (Signing.signSubTransaction key local)
  signedId <- ExceptT (Sub.transactionId signed)
  except (unless (identifier == signedId) (Left (InvalidBuildingRequest "Signing changed an intent body")))
  pure signed

settle :: Parameters -> AssetId -> Party -> Party -> Party -> IO (Either Error Swap)
settle params token buyer@(Party _ _ buyerInput _) seller@(Party _ _ sellerInput _) (Party address guard batcherInput key) = runExceptT $ do
  buyerSub <- ExceptT (signedIntent params token guard buyer 50000000 1000)
  sellerSub <- ExceptT (signedIntent params token guard seller 60000000 4000)
  let settings = (Builder.defaultConfig params Slots.preprod address) {Builder.availableUtxos = [batcherInput]}
      plan = Plan.attachSubTransaction buyerSub [buyerInput] <> Plan.attachSubTransaction sellerSub [sellerInput] <> Plan.requireGuard guard
  batch <- ExceptT (Builder.build settings plan)
  signed <- ExceptT (Signing.sign key batch)
  let resolved = [buyerInput, sellerInput, batcherInput]
      preserved = fmap (map Sub.encodeCbor) (Body.bodySubTransactions (Body.toBody (Tx.body signed)))
  except (unless (preserved == Just [Sub.encodeCbor buyerSub, Sub.encodeCbor sellerSub]) (Left (InvalidBuildingRequest "Batch changed independently signed intent bytes")))
  balanced <- ExceptT (Building.isBalanced params resolved signed)
  except (unless balanced (Left (InvalidBuildingRequest "Two-party swap does not conserve value")))
  pure (Swap signed buyerSub sellerSub resolved)
