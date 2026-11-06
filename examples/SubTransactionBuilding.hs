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

-- | Build and sign an offline intent, then balance and sign its enclosing batch.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error (InvalidBuildingRequest))
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Builder as SubBuilder
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import qualified Data.Text.IO as Text
import qualified Fixtures.ProtocolParameters as Fixture
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  -- Unfunded demonstration key and synthetic input references; no network calls.
  result <- Key.withNormalKey (ByteString.replicate 32 7) $ \key -> runExceptT $ do
    raw <- except Fixture.parameters
    public <- ExceptT (Key.publicKey key)
    credential <- ExceptT (Credential.fromPublicKey public)
    subReference <- except (Id.fromBytes (ByteString.replicate 32 8))
    parentReference <- except (Id.fromBytes (ByteString.replicate 32 9))
    let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet credential)
        params =
          raw
            { Parameters.parameterMinFeeA = 44,
              Parameters.parameterMinFeeB = 155381,
              Parameters.parameterMaxTxSize = 16384,
              Parameters.parameterMaxValueSize = Just 5000,
              Parameters.parameterAdaPerUtxoByte = Just 4310,
              Parameters.parameterProtocolVersion = Version.ProtocolVersion 12 0
            }
    funding <- except (Output.mkOutput destination (Value.lovelace 10000000) Datum.NoDatum Nothing)
    localPayment <- except (Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing)
    parentPayment <- except (Output.mkOutput destination (Value.lovelace 15000000) Datum.NoDatum Nothing)
    let subInput = Utxo.utxo (Input.input subReference 0) funding
        parentInput = Utxo.utxo (Input.input parentReference 0) funding
        intent = SubPlan.spend subInput <> SubPlan.payTo localPayment
    local <- ExceptT (SubBuilder.build (SubBuilder.Config params Slots.preview Fields.Testnet) intent)
    signedIntent <- ExceptT (Signing.signSubTransaction key local)
    let config = (Builder.defaultConfig params Slots.preview destination) {Builder.availableUtxos = [parentInput]}
        plan = Plan.attachSubTransaction signedIntent (SubPlan.resolvedInputs intent) <> Plan.payTo parentPayment
    batch <- ExceptT (Builder.build config plan)
    signedBatch <- ExceptT (Signing.sign key batch)
    balanced <- ExceptT (Building.isBalanced params [subInput, parentInput] signedBatch)
    except (if balanced then Right () else Left (InvalidBuildingRequest "Example batch is not balanced"))
    localId <- ExceptT (Sub.transactionId signedIntent)
    batchId <- ExceptT (Tx.transactionId signedBatch)
    pure (localId, batchId)
  case result of
    Left failure -> die (show failure)
    Right (localId, batchId) -> do
      Text.putStrLn (Id.toHex localId)
      Text.putStrLn (Id.toHex batchId)
