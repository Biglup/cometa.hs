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

-- | Offline account deposits, a treasury donation, and governance construction.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.Transaction as Transaction
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
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
              Parameters.parameterGovernanceActionDeposit = Just 100000
            }

    funding <- except (Output.mkOutput destination (Value.lovelace 10000000) Datum.NoDatum Nothing)
    payment <- except (Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing)

    stakeKey <- except (Credential.keyHashFromBytes (B.replicate 28 9))
    guardKey <- except (Credential.keyHashFromBytes (B.replicate 28 7))
    voterKey <- except (Credential.keyHashFromBytes (B.replicate 28 5))
    metadataUrl <- except (Anchor.mkUrl "https://example.com/proposal")
    metadataHash <- except (Anchor.dataHashFromBytes (B.replicate 32 0))

    let account = Reward.fromCredential Network.testnet (Credential.KeyCredential stakeKey)
        metadata = Anchor.Anchor metadataUrl metadataHash
        voter = Voting.DRepVoter (Credential.KeyCredential voterKey)
        action = ActionId.ActionId previous 0
        config =
          (Builder.defaultConfig params Slot.preview destination)
            { Builder.availableUtxos = [Utxo.utxo (Input.input previous 0) funding]
            }
        plan =
          Plan.payTo payment
            <> Plan.requireGuard (Credential.KeyCredential guardKey)
            <> Plan.directDeposit account 1000000
            <> Plan.accountBalance account (Fields.BalanceRange (Just 0) (Just 5000000))
            <> Plan.startingAccountBalance account (Fields.ExactBalance 2000000)
            <> Plan.donate 100000
            <> Plan.propose account Action.InfoAction metadata
            <> Plan.vote voter action (Voting.VotingProcedure Voting.Yes Nothing)
            <> Plan.validUntil 1000000

    transaction <- ExceptT (Builder.build config plan)
    pure (Body.toBody (Transaction.body transaction))

  case result of
    Left failure -> die (show failure)
    Right body -> print body
