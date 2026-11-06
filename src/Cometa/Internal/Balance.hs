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
{-# OPTIONS_HADDOCK hide #-}

-- | Checked accounting before native signed arithmetic. Parsed native owners
-- remain scoped by the existing standalone building transport.
module Cometa.Internal.Balance (imbalance, subTransactionImbalance, batchImbalance, isBalanced) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Building as Building
import qualified Cometa.Internal.ParameterSnapshot as Snapshot
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Internal.TransactionValue as ValueCbor
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Word (Word64)
import Foreign.C.Types (CUInt)

-- DEFINITIONS ----------------------------------------------------------------

imbalance :: Parameters.Parameters -> [Utxo.Utxo] -> Tx.Transaction -> IO (Either Error Value.Value)
imbalance parameters resolved transaction = runExceptT $ do
  except (validateResolved resolved)
  implicit <- ExceptT (Building.implicitCoin parameters transaction)
  let body = Body.toBody (Tx.body transaction)
  _ <- except (bodyBalance resolved (Body.fee body) (Body.bodyFields body) implicit)
  ExceptT (compute 6 parameters resolved (Tx.encodeCbor transaction))

subTransactionImbalance :: Parameters.Parameters -> [Utxo.Utxo] -> Sub.SubTransaction -> IO (Either Error Value.Value)
subTransactionImbalance parameters resolved transaction = runExceptT $ do
  except (validateResolved resolved)
  implicit <- ExceptT (Building.subTransactionImplicitCoin parameters transaction)
  _ <- except (bodyBalance resolved 0 (SubBody.fields (SubBody.toBody (Sub.body transaction))) implicit)
  ExceptT (compute 7 parameters resolved (Sub.encodeCbor transaction))

batchImbalance :: Parameters.Parameters -> [Utxo.Utxo] -> Tx.Transaction -> IO (Either Error Value.Value)
batchImbalance parameters resolved transaction = runExceptT $ do
  except (validateResolved resolved)
  let body = Body.toBody (Tx.body transaction)
      subs = fromMaybe [] (Body.bodySubTransactions body)
      fields = Body.bodyFields body : map (SubBody.fields . SubBody.toBody . Sub.body) subs
  outer <- ExceptT (Building.implicitCoin parameters transaction)
  nested <- traverse (ExceptT . Building.subTransactionImplicitCoin parameters) subs
  values <- except (sequence (zipWith3 (bodyBalance resolved) (Body.fee body : repeat 0) fields (outer : nested)))
  -- Native set iteration order need not match imported envelopes. Bounding the
  -- positive and negative totals separately protects every possible prefix.
  let positives = Value.fromList [(asset, amount) | value <- values, (asset, amount) <- Value.toList value, amount > 0]
      negatives = Value.fromList [(asset, amount) | value <- values, (asset, amount) <- Value.toList value, amount < 0]
      refund = Value.lovelace (repeatedPoolRefund parameters fields)
  except (bounded (positives <> refund) >> bounded negatives)
  ExceptT (compute 8 parameters resolved (Tx.encodeCbor transaction))

isBalanced :: Parameters.Parameters -> [Utxo.Utxo] -> Tx.Transaction -> IO (Either Error Bool)
isBalanced parameters resolved transaction = fmap (fmap (== mempty)) (batchImbalance parameters resolved transaction)

validateResolved :: [Utxo.Utxo] -> Either Error ()
validateResolved resolved =
  unless
    (Set.size (Set.fromList (map Utxo.input resolved)) == length resolved)
    (Left (InvalidBuildingRequest "Duplicate resolved spending input"))

bodyBalance :: [Utxo.Utxo] -> Word64 -> Fields.Fields -> Building.ImplicitCoin -> Either Error Value.Value
bodyBalance resolved fee fields implicit = do
  inputs <- traverse resolve (Fields.fieldInputs fields)
  let inputValue = foldMap (Output.value . Utxo.output) inputs
      outputValue = foldMap Output.value (Fields.fieldOutputs fields)
      mint = maybe mempty Fields.mintValue (Fields.fieldMint fields)
      consumedCoin = toInteger (Building.withdrawals implicit) + toInteger (Building.reclaimedDeposits implicit)
      producedCoin =
        toInteger fee
          + toInteger (Building.deposits implicit)
          + maybe 0 toInteger (Fields.fieldDonation fields)
          + sum [toInteger amount | (_, amount) <- maybe [] Fields.entries (Fields.fieldDirectDeposits fields)]
      consumed = inputValue <> Value.lovelace consumedCoin <> mint
      difference = consumed <> negateValue outputValue
      result = difference <> Value.lovelace (negate producedCoin)
  mapM_ bounded [inputValue, outputValue, Value.lovelace consumedCoin, Value.lovelace producedCoin, consumed, difference, result]
  pure result
  where
    table = Map.fromList [(Utxo.input value, value) | value <- resolved]
    resolve reference = maybe (Left (InvalidBuildingRequest "A spending input has no resolved UTxO")) Right (Map.lookup reference table)

bounded :: Value.Value -> Either Error ()
bounded value = unless (all fits (Value.toList value)) (Left (InvalidBuildingRequest "Balance intermediate exceeds signed 64-bit bounds"))
  where
    fits (_, amount) = amount >= toInteger (minBound :: Int64) && amount <= toInteger (maxBound :: Int64)

negateValue :: Value.Value -> Value.Value
negateValue = Value.fromList . map (fmap negate) . Value.toList

repeatedPoolRefund :: Parameters.Parameters -> [Fields.Fields] -> Integer
repeatedPoolRefund parameters fields =
  toInteger (sum (map Set.size pools) - Set.size (Set.unions pools)) * toInteger (Parameters.parameterPoolDeposit parameters)
  where
    pools = map (Set.fromList . map Pool.operator . registrations) fields
    registrations body = [pool | Certificate.PoolRegistration pool <- maybe [] Certificates.toList (Fields.fieldCertificates body)]

compute :: CUInt -> Parameters.Parameters -> [Utxo.Utxo] -> ByteString -> IO (Either Error Value.Value)
compute operation parameters resolved transaction = do
  result <- Building.runUnchecked operation (Cbor.encode request)
  pure (result >>= Cbor.decodeAs InvalidBuildingRequest decoder)
  where
    request =
      E.encodeListLen 3
        <> Cbor.raw transaction
        <> Cbor.raw (Snapshot.encodeSnapshot parameters)
        <> E.encodeListLen (fromIntegral (length resolved))
        <> foldMap (Cbor.raw . Utxo.encodeCbor) resolved
    decoder = Cbor.array 2 (((<>) . Value.lovelace <$> D.decodeInteger) <*> ValueCbor.decodeAssets)
