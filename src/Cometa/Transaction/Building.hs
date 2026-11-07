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

-- | Standalone transaction building calculations. Obtain a protocol snapshot,
-- assemble outputs and witnesses, evaluate scripts, then calculate commitments
-- and fees explicitly. Calculations leave the supplied transaction unchanged.
--
-- @
-- import qualified Cometa.Transaction.Building as Building
--
-- priceOutput output = Building.minimumAda 4310 output
-- @
module Cometa.Transaction.Building
  ( coinSize,
    outputSize,
    scriptSize,
    transactionSize,
    totalExecutionUnits,
    minimumAda,
    baseFee,
    minimumFee,
    executionFee,
    referenceScriptFee,
    scriptDataHash,
    ImplicitCoin (..),
    implicitCoin,
    subTransactionImplicitCoin,
    imbalance,
    subTransactionImbalance,
    batchImbalance,
    isBalanced,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Write as Write
import Cometa.Error (Error (InvalidBuildingRequest))
import qualified Cometa.Internal.Balance as Balance
import Cometa.Internal.Building (ImplicitCoin (..))
import qualified Cometa.Internal.Building as Internal
import Cometa.Protocol.CostModels (CostModels)
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as ExUnits
import Cometa.Protocol.Parameters (Parameters)
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as NativeScript
import qualified Cometa.Script.Plutus as PlutusScript
import Cometa.SubTransaction (SubTransaction)
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import Cometa.Transaction.Datum (Hash32)
import Cometa.Transaction.Output (Output)
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import Cometa.Transaction.Utxo (Utxo)
import Cometa.Transaction.Witnesses (EncodedWitnesses)
import Cometa.Value (Value)
import qualified Data.ByteString as ByteString
import Data.Word (Word64)

-- DEFINITIONS ----------------------------------------------------------------

-- | Size in bytes of the shortest unsigned CBOR encoding of a lovelace amount.
-- Zero through 23 require one byte; every unsigned 64-bit amount is supported.
coinSize :: Word64 -> Int
coinSize = ByteString.length . Write.toStrictByteString . Encode.encodeWord64

-- | Size in bytes of this output's public CBOR encoding, including its value,
-- datum and reference script. Does not calculate the minimum required Ada.
outputSize :: Output -> Int
outputSize = ByteString.length . Output.encodeCbor

-- | Script size in bytes charged by reference-script pricing. Native scripts
-- use their exact CBOR; Plutus scripts use their compiled bytes without the
-- outer CBOR bytestring or the language-tag envelope.
scriptSize :: Script.Script -> Int
scriptSize script = case script of
  Script.Native native -> ByteString.length (NativeScript.encodeCbor native)
  Script.Plutus plutus -> ByteString.length (PlutusScript.toBytes plutus)

-- | Complete encoded transaction size in bytes, including the validity flag
-- when present, actual witnesses and auxiliary data. This is not the ledger
-- size used by 'baseFee', which excludes the validity flag.
transactionSize :: Transaction -> Int
transactionSize = ByteString.length . Tx.encodeCbor

-- | Sum declared memory units and CPU steps without executing scripts. Counts
-- every supplied redeemer, including repeated purpose/index pairs. Empty input
-- returns zero. Either total exceeding 2^64-1 returns 'Cometa.Error.InvalidExUnits'
-- rather than wrapping. Nested transaction redeemers must be supplied explicitly.
totalExecutionUnits :: [Redeemer.Redeemer] -> Either Error ExUnits.ExUnits
totalExecutionUnits redeemers =
  ExUnits.mkExUnits
    (sum (map (toInteger . ExUnits.memory . Redeemer.executionUnits) redeemers))
    (sum (map (toInteger . ExUnits.steps . Redeemer.executionUnits) redeemers))

-- | Minimum output coin in lovelace, accounting for the size of the resulting
-- coin encoding. The first argument is lovelace per UTxO byte. Zero is allowed;
-- amounts exceeding native 64-bit calculation bounds return a native error.
minimumAda :: Word64 -> Output -> IO (Either Error Word64)
minimumAda = Internal.minimumAda

-- | Linear fee in lovelace: constant plus coefficient times ledger transaction
-- size, excluding the script-validity flag. Arguments are the constant lovelace
-- charge, then lovelace per byte. Uses actual included witnesses and auxiliary
-- data; callers must account for any witnesses they intend to add. Overflow is
-- an error. No execution or reference script charge is included.
baseFee :: Word64 -> Word64 -> Transaction -> IO (Either Error Word64)
baseFee = Internal.baseFee

-- | Fee in lovelace for the complete supplied transaction, including execution
-- units of top-level and subtransaction redeemers and reference script prices.
-- Resolved UTxOs must be unique and cover exactly the union of spending and
-- reference inputs in all bodies. A reference script is charged once per UTxO
-- within each body, even if both spent and referenced there. The same UTxO
-- appearing in several bodies is priced for each body. Missing execution or reference prices and invalid coverage
-- return 'Cometa.Error.InvalidBuildingRequest'. Uses actual included witnesses;
-- adding signatures or changing budgets requires recalculation. No evaluation,
-- witness estimation, input resolution or fee installation is performed.
minimumFee :: Parameters -> [Utxo] -> Transaction -> IO (Either Error Word64)
minimumFee = Internal.minimumFee

-- | Exact execution charge in lovelace for supplied prices and aggregate
-- budgets: round the sum of memory and CPU charges upward once. Does not price
-- reference scripts or execute scripts. Zero budgets cost zero. A result above
-- 2^64-1 returns 'Cometa.Error.InvalidBuildingRequest'. Aggregate transaction and
-- subtransaction redeemers with 'totalExecutionUnits' before pricing a batch.
executionFee :: Prices.ExUnitPrices -> ExUnits.ExUnits -> Either Error Word64
executionFee prices units =
  let charge =
        fromIntegral (ExUnits.memory units) * Rational.toRational (Prices.memoryPrice prices)
          + fromIntegral (ExUnits.steps units) * Rational.toRational (Prices.stepPrice prices)
      rounded = ceiling charge :: Integer
   in if rounded <= toInteger (maxBound :: Word64)
        then Right (fromInteger rounded)
        else Left (InvalidBuildingRequest "Execution fee exceeds the unsigned 64-bit range")

-- | Price reference scripts in exactly these unique resolved UTxOs, in lovelace.
-- Uses exact rational tier prices and floors the total once. Missing stride or
-- multiplier uses Conway values 25600 bytes and 6/5; supplied values use protocol
-- tiers. A reference byte price is required. Duplicate references are invalid.
referenceScriptFee :: Parameters -> [Utxo] -> IO (Either Error Word64)
referenceScriptFee = Internal.referenceScriptFee

-- | Script-data commitment for the exact redeemer and datum field encodings in
-- these witnesses. Supply only cost models for the languages used by the body:
-- every supplied language view contributes when redeemers are present. No
-- redeemers and no datums returns 'Nothing'; datum-only witnesses use empty
-- language views. Does not install the commitment in a body or evaluate scripts.
scriptDataHash :: CostModels -> EncodedWitnesses -> IO (Either Error (Maybe Hash32))
scriptDataHash = Internal.scriptDataHash

-- | Top-level body's withdrawals, paid deposits and reclaimed deposits. Nested
-- subtransactions are excluded. Each pool is charged once within this body;
-- already registered pools are also charged because no chain registration state
-- is supplied. Pool retirement refunds occur at epoch boundaries and contribute
-- zero here. This is an accounting component, not a ledger balance assertion.
-- Native unsigned 64-bit overflow is reported as an error.
implicitCoin :: Parameters -> Transaction -> IO (Either Error ImplicitCoin)
implicitCoin = Internal.implicitCoin

-- | The same accounting as 'implicitCoin' for one subtransaction body. Pool
-- deposits are charged once per pool within this body, independently of other
-- bodies in a batch; this does not compute the deduplicated batch balance.
subTransactionImplicitCoin :: Parameters -> SubTransaction -> IO (Either Error ImplicitCoin)
subTransactionImplicitCoin = Internal.subTransactionImplicitCoin

-- | Top-level consumed value minus produced value. Positive quantities are a
-- surplus; negative quantities are a deficit. Includes mint/burn, withdrawals,
-- refunds, deposits, fee, donation and direct deposits; excludes nested bodies.
-- Resolve every spending input exactly once. Extra resolved UTxOs are allowed;
-- reference and collateral inputs do not contribute. Signed 64-bit intermediate
-- overflow or missing/duplicate resolution returns 'Cometa.Error.InvalidBuildingRequest'.
imbalance :: Parameters -> [Utxo] -> Transaction -> IO (Either Error Value)
imbalance = Balance.imbalance

-- | The same accounting for one subtransaction, which has no fee. A nonzero
-- result is normal for an intent awaiting matching in a batch.
subTransactionImbalance :: Parameters -> [Utxo] -> SubTransaction -> IO (Either Error Value)
subTransactionImbalance = Balance.subTransactionImbalance

-- | Whole-batch surplus or deficit, charging each registered pool's deposit
-- once across all bodies. Supply a unique resolved snapshot covering spending
-- inputs at every level. Positive and negative intermediate totals must each
-- fit signed 64-bit bounds. This checks value conservation, not ledger admission,
-- signatures, script success or availability of inputs on chain.
batchImbalance :: Parameters -> [Utxo] -> Transaction -> IO (Either Error Value)
batchImbalance = Balance.batchImbalance

-- | Whether the complete batch has zero coin and asset imbalance. Does not
-- validate other ledger rules. Resolution and arithmetic errors remain explicit.
isBalanced :: Parameters -> [Utxo] -> Transaction -> IO (Either Error Bool)
isBalanced = Balance.isBalanced
