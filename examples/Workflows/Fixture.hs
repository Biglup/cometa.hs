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

-- | Deterministic provider state for executing example stages without HTTP.
-- This checks signed bytes and conservation; it does not emulate ledger rules.
module Workflows.Fixture (Fixture (..), withFixture, verifyTransaction) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.PublicKey as Public
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import Cometa.Error (Error (..))
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.ExUnitPrices as Prices
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as B
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import qualified Fixtures.ProtocolParameters as Raw
import qualified Workflows.Native as Workflow

-- TYPES ----------------------------------------------------------------------

data Fixture = Fixture
  { submitted :: IO [Tx.Transaction],
    currentUtxos :: IO [Utxo.Utxo],
    stakeCredential :: Credential.Credential Credential.Stake,
    drepCredential :: Credential.Credential Credential.DRep,
    paymentHash :: Credential.KeyHash Credential.Payment,
    signIntent :: Sub.SubTransaction -> IO (Either Error Sub.SubTransaction)
  }

-- DEFINITIONS ----------------------------------------------------------------

withFixture :: (Workflow.Context -> Fixture -> IO (Either Error a)) -> IO (Either Error a)
withFixture action = Key.withNormalKey (B.replicate 32 7) $ \key -> do
  prepared <- runExceptT $ do
    raw <- except Raw.parameters
    zero <- except (Rational.mkNonNegativeRational 0 1)
    models <- except (traverse (\(language, count) -> Models.mkCostModel language (replicate count 100)) [(0, 166), (1, 175), (2, 251), (3, 369)])
    public <- ExceptT (Key.publicKey key)
    payment <- ExceptT (Credential.fromPublicKey public)
    stake <- ExceptT (Credential.fromPublicKey public)
    drep <- ExceptT (Credential.fromPublicKey public)
    hash <- case payment of
      Credential.KeyCredential value -> pure value
      Credential.ScriptCredential _ -> except (Left (InvalidBuildingRequest "Expected public-key credential"))
    previous <- except (Id.fromBytes (B.replicate 32 8))
    collateralId <- except (Id.fromBytes (B.replicate 32 9))
    let address = Address.ShelleyAddress (Shelley.base Network.testnet payment stake)
        params =
          raw
            { Parameters.parameterMinFeeA = 0,
              Parameters.parameterMinFeeB = 0,
              Parameters.parameterMaxTxSize = 65536,
              Parameters.parameterMaxValueSize = Just 5000,
              Parameters.parameterAdaPerUtxoByte = Just 4310,
              Parameters.parameterProtocolVersion = Version.ProtocolVersion 12 0,
              Parameters.parameterCostModels = Just (Models.fromList models),
              Parameters.parameterExecutionCosts = Just (Prices.ExUnitPrices zero zero),
              Parameters.parameterRefScriptCostPerByte = Just zero,
              Parameters.parameterMaxTxExUnits = Just (ExUnits 100000000 100000000000),
              Parameters.parameterCollateralPercentage = Just 150,
              Parameters.parameterMaxCollateralInputs = Just 3,
              Parameters.parameterKeyDeposit = 2000000,
              Parameters.parameterDrepDeposit = Just 2000000,
              Parameters.parameterGovernanceActionDeposit = Just 1000000
            }
    funding <- except (Output.mkOutput address (Value.lovelace 2000000000) Datum.NoDatum Nothing)
    collateral <- except (Output.mkOutput address (Value.lovelace 50000000) Datum.NoDatum Nothing)
    pure (params, address, stake, drep, hash, Utxo.utxo (Input.input previous 0) funding, Utxo.utxo (Input.input collateralId 0) collateral)
  case prepared of
    Left failure -> pure (Left failure)
    Right (params, address, stake, drep, hash, funding, reserved) -> do
      utxos <- newIORef [funding, reserved]
      history <- newIORef []
      let backend =
            (Provider.unavailable "Native example fixture" 42)
              { Provider.protocolParameters = pure (Right params),
                Provider.utxosAt = \target -> Right . filter ((== target) . Output.address . Utxo.output) <$> readIORef utxos,
                Provider.rewardBalance = \_ -> pure (Right 0),
                Provider.resolveInputs = \references -> Right . filter (\value -> Utxo.input value `elem` references) <$> readIORef utxos,
                Provider.submitTransaction = apply params utxos history,
                Provider.awaitTransaction = \identifier _ -> do
                  values <- readIORef history
                  identifiers <- traverse Tx.transactionId values
                  pure (elem identifier <$> sequence identifiers)
              }
          context = Workflow.Context backend address (Signer.ed25519 key) Network.testnet Slots.preview 1000000 [Utxo.input reserved] 1 1000
          fixture = Fixture (readIORef history) (readIORef utxos) stake drep hash (Signing.signSubTransaction key)
      action context fixture

apply :: Parameters.Parameters -> IORef [Utxo.Utxo] -> IORef [Tx.Transaction] -> Tx.Transaction -> IO (Either Error Id.TransactionId)
apply params utxos history transaction = runExceptT $ do
  before <- ExceptT (Right <$> readIORef utxos)
  ExceptT (verifyTransaction transaction)
  balanced <- ExceptT (Building.isBalanced params before transaction)
  except (unless balanced (Left (InvalidBuildingRequest "Example transaction does not conserve value")))
  identifier <- ExceptT (Tx.transactionId transaction)
  nested <- traverse (ExceptT . subOutputs) (fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction))))
  let body = Body.toBody (Tx.body transaction)
      spent = Fields.fieldInputs (Body.bodyFields body) <> maybe [] (concatMap (Fields.fieldInputs . SubBody.fields . SubBody.toBody . Sub.body)) (Body.bodySubTransactions body)
      created = [Utxo.utxo (Input.input identifier index) output | (index, output) <- zip [0 ..] (Fields.fieldOutputs (Body.bodyFields body))] <> concat nested
      after = filter (\value -> Utxo.input value `notElem` spent) before <> created
  ExceptT (writeIORef utxos after >> modifyIORef' history (<> [transaction]) >> pure (Right ()))
  pure identifier

subOutputs :: Sub.SubTransaction -> IO (Either Error [Utxo.Utxo])
subOutputs transaction = do
  identifier <- Sub.transactionId transaction
  pure $ do
    digest <- identifier
    pure [Utxo.utxo (Input.input digest index) output | (index, output) <- zip [0 ..] (Fields.fieldOutputs (SubBody.fields (SubBody.toBody (Sub.body transaction))))]

-- | Verify every outer and nested verification witness against its own exact
-- body hash before fixture submission can mutate UTxOs or accepted-ID history.
verifyTransaction :: Tx.Transaction -> IO (Either Error ())
verifyTransaction transaction = runExceptT $ do
  outer <- ExceptT (Tx.transactionId transaction)
  ExceptT (verifyWitnesses (Id.toBytes outer) (Tx.witnesses transaction))
  let nested = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
  mapM_ verifySub nested
  where
    verifySub intent = do
      identifier <- ExceptT (Sub.transactionId intent)
      ExceptT (verifyWitnesses (Id.toBytes identifier) (Sub.witnesses intent))

verifyWitnesses :: B.ByteString -> Witnesses.EncodedWitnesses -> IO (Either Error ())
verifyWitnesses message encoded = runExceptT $ do
  let values = Witnesses.verificationWitnesses (Witnesses.toWitnesses encoded)
  except (when (null values) (Left (InvalidBuildingRequest "Fixture expected signed transaction")))
  mapM_ verify values
  where
    verify witness = do
      valid <- ExceptT (Public.verify (Witness.publicKey witness) message (Witness.signature witness))
      except (unless valid (Left (InvalidBuildingRequest "Fixture verification witness does not verify against its transaction body")))
