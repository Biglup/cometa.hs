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

-- | An offline payment build with synthetic wallet inputs and explicit snapshots.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.Transaction as Transaction
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import qualified Data.Text.IO as Text
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
              Parameters.parameterProtocolVersion = Version.ProtocolVersion 10 0
            }

    funding <- except (Output.mkOutput destination (Value.lovelace 10000000) Datum.NoDatum Nothing)
    payment <- except (Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing)

    let config =
          (Builder.defaultConfig params Slot.preview destination)
            { Builder.availableUtxos = [Utxo.utxo (Input.input previous 0) funding]
            }
        plan = Plan.payTo payment <> Plan.validUntil 1000000

    transaction <- ExceptT (Builder.build config plan)
    ExceptT (Transaction.transactionId transaction)

  case result of
    Left failure -> die (show failure)
    Right identifier -> Text.putStrLn (TxId.toHex identifier)
