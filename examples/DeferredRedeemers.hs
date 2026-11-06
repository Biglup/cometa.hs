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

-- | An offline native mint with an argument computed from the balanced draft.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.Transaction as Transaction
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import qualified Fixtures.ProtocolParameters as Fixture
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  result <- runExceptT $ do
    raw <- except Fixture.parameters
    key <- except (Credential.keyHashFromBytes (B.replicate 28 7))
    model <- except (Models.mkCostModel 3 (replicate 369 100))
    previous <- except (TxId.fromBytes (B.replicate 32 8))
    let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
        params =
          raw
            { Parameters.parameterMinFeeA = 44,
              Parameters.parameterMinFeeB = 155381,
              Parameters.parameterMaxTxSize = 16384,
              Parameters.parameterMaxValueSize = Just 5000,
              Parameters.parameterAdaPerUtxoByte = Just 4310,
              Parameters.parameterProtocolVersion = Version.ProtocolVersion 12 0,
              Parameters.parameterCostModels = Just (Models.fromList [model]),
              Parameters.parameterMaxTxExUnits = Just (ExUnits 100000000 100000000000),
              Parameters.parameterCollateralPercentage = Just 150,
              Parameters.parameterMaxCollateralInputs = Just 3
            }

    funding <- except (Output.mkOutput destination (Value.lovelace 10000000) Datum.NoDatum Nothing)
    payment <- except (Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing)

    -- Single-CBOR-wrapped Flat lambda returning unit, UPLC version 1.1.0.
    policyScript <- except (Plutus.fromBytes Plutus.V4 (B.pack [0x45, 1, 1, 0, 0x24, 0x99]))
    digest <- ExceptT (Plutus.hash policyScript)
    collateralId <- except (TxId.fromBytes (B.replicate 32 9))
    collateral <- except (Output.mkOutput destination (Value.lovelace 5000000) Datum.NoDatum Nothing)

    let config =
          (Builder.defaultConfig params Slot.preview destination)
            { Builder.availableUtxos = [Utxo.utxo (Input.input previous 0) funding],
              Builder.collateralUtxos = [Utxo.utxo (Input.input collateralId 0) collateral]
            }
        policy = Policy.fromScriptHash digest
        plan =
          Plan.payTo payment
            <> Plan.attachScript (Script.Plutus policyScript)
            <> Plan.mintWithDeferredRedeemer policy [(AssetName.empty, 1)] describeDraft
            <> Plan.validUntil 1000000

    transaction <- ExceptT (Builder.build config plan)
    pure (map Redeemer.argument (Witnesses.redeemers (Witnesses.toWitnesses (Transaction.witnesses transaction))))

  case result of
    Left failure -> die (show failure)
    Right arguments -> print arguments

-- Every invocation uses only the supplied immutable snapshots. Include selected
-- input count, final output count (including change), and fee in lovelace.
describeDraft :: Plan.DeferredRedeemer
describeDraft transaction selected =
  let body = Body.toBody (Transaction.body transaction)
      fields = Body.bodyFields body
   in if length selected /= length (Fields.fieldInputs fields)
        then Left (InvalidTransactionPlan "Selected inputs do not match the draft")
        else
          Right
            ( Data.fromData
                ( Data.Constr
                    0
                    [ Data.Integer (toInteger (length selected)),
                      Data.Integer (toInteger (length (Fields.fieldOutputs fields))),
                      Data.Integer (toInteger (Body.fee body))
                    ]
                )
            )
