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

-- | Offline mnemonic -> encrypted handler -> reload -> address -> signed payment.
-- The phrase and password are public demonstration material; never fund it.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.Bip39 as Bip39
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error (..))
import qualified Cometa.KeyHandler.Software as Software
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text.IO as Text
import qualified Fixtures.ProtocolParameters as Fixture
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  let password = "public demonstration password"
  result <- runExceptT $ do
    mnemonic <- except (Bip39.fromText "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
    entropy <- except (Bip39.exportEntropy mnemonic)
    stored <- ExceptT (Software.withEntropy entropy password (pure password) Software.serialize)
    ExceptT (Software.withSerialized stored (pure password) useRecovered)
  case result of
    Left failure -> die (show failure)
    Right (address, identifier) -> do
      Text.putStrLn (Address.toText address)
      Text.putStrLn (Id.toHex identifier)

useRecovered :: Software.LoadedHandler -> IO (Either Error (Address.Address, Id.TransactionId))
useRecovered loaded = case loaded of
  Software.Ed25519Handler _ -> pure (Left (InvalidCallbackResult "Mnemonic recovery expected a BIP32 handler"))
  Software.Bip32Handler handler -> runExceptT $ do
    let account = Path.standardAccountPath minBound
        paymentPath = Path.derivationPath account Path.externalRole minBound
        stakePath = Path.derivationPath account Path.stakingRole minBound
    public <- ExceptT (Software.accountPublicKey handler account)
    paymentPublic <- ExceptT (Public.derive public (Path.relativeIndices paymentPath))
    stakePublic <- ExceptT (Public.derive public (Path.relativeIndices stakePath))
    payment <- ExceptT (Credential.fromPublicKey (Public.toEd25519 paymentPublic))
    stake <- ExceptT (Credential.fromPublicKey (Public.toEd25519 stakePublic))
    let address = Address.ShelleyAddress (Shelley.base Network.testnet payment stake)
    raw <- except Fixture.parameters
    previous <- except (Id.fromBytes (B.replicate 32 8))
    let params =
          raw
            { Parameters.parameterMinFeeA = 44,
              Parameters.parameterMinFeeB = 155381,
              Parameters.parameterMaxTxSize = 16384,
              Parameters.parameterMaxValueSize = Just 5000,
              Parameters.parameterAdaPerUtxoByte = Just 4310,
              Parameters.parameterProtocolVersion = Version.ProtocolVersion 10 0
            }
    funding <- except (Output.mkOutput address (Value.lovelace 10000000) Datum.NoDatum Nothing)
    output <- except (Output.mkOutput address (Value.lovelace 2000000) Datum.NoDatum Nothing)
    let settings = (Builder.defaultConfig params Slots.preview address) {Builder.availableUtxos = [Utxo.utxo (Input.input previous 0) funding]}
    unsigned <- ExceptT (Builder.build settings (Plan.payTo output))
    witnesses <- ExceptT (Software.signTransactionAt handler (paymentPath :| []) unsigned)
    signed <- except (Tx.addWitnesses witnesses unsigned)
    identifier <- ExceptT (Tx.transactionId signed)
    pure (address, identifier)
