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

-- | Operation-owned native sub-builder. Runtime roots callback plans through
-- native builder destruction and joins callback cancellation before scope exit.
module Cometa.Internal.SubTransactionBuilder (Config (..), build, runUnchecked, runWithDispatch, dispatch) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.AssetId (AssetId (Ada))
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.FFI.Native as Status
import qualified Cometa.Internal.FFI.Runtime as Raw
import qualified Cometa.Internal.FFI.SubTransactionBuilder as FFI
import qualified Cometa.Internal.ParameterSnapshot as Snapshot
import qualified Cometa.Internal.Runtime as Runtime
import Cometa.Internal.SubTransactionPlan (Plan)
import qualified Cometa.Internal.SubTransactionPlan as Plan
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Internal.TransactionPlan as Common
import qualified Cometa.Internal.TransactionValue as ValueCbor
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.ExUnits as Ex
import Cometa.Protocol.Parameters (Parameters)
import qualified Cometa.Protocol.Parameters as Parameters
import Cometa.SlotConfig (SlotConfig)
import qualified Cometa.SlotConfig as Slots
import Cometa.SubTransaction (SubTransaction)
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import Cometa.Transaction.Fields (BodyNetwork (..))
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.Value as Value
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Sequence as Seq
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | Context for building an intent. Protocol parameters supply deposits, cost
-- models and language availability; the schedule converts explicit validity
-- slots, and the network is written into the local body.
data Config = Config
  { -- | Complete protocol parameter snapshot.
    parameters :: !Parameters,
    -- | Constant-duration schedule in Unix milliseconds.
    slotConfig :: !SlotConfig,
    -- | Ledger body network, distinct from network magic.
    networkId :: !BodyNetwork
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Build exactly the requested inputs and outputs with no fee, collateral,
-- balancing or change. Deferred arguments run once on the local zero-fee draft
-- before native V4 evaluation and script-data commitment. An unused or cancelled
-- mint group does not invoke its callback. Native expected errors return 'Left';
-- callback exceptions propagate after native cleanup. Aggregate quantities and
-- deposits must fit signed 64-bit. The result must fit the configured transaction
-- size and execution limits, and output values must fit their configured limit.
-- Later signatures and enclosing fields consume additional transaction space.
--
-- Scripts are evaluated at position zero in an otherwise empty enclosing batch.
-- A script that depends on the actual batch position or surrounding transaction
-- can need different budgets or fail when later assembled. Building does not
-- establish complete ledger admission, balance or the freshness of inputs.
build :: Config -> Plan -> IO (Either Error SubTransaction)
build config plan = case validate config plan of
  Left failure -> pure (Left failure)
  Right () -> do
    result <- runUnchecked config plan (Common.encodePlan (fromMaybe 0 (Parameters.parameterGovernanceActionDeposit (parameters config))) (Plan.toPlan plan))
    pure $ do
      bytes <- result
      transaction <- Sub.decodeCbor bytes
      validateBuilt config transaction
      pure transaction

validate :: Config -> Plan -> Either Error ()
validate config plan = do
  Snapshot.validateNative params
  Common.validatePlan common
  mapM_ (Slots.slotToTime (slotConfig config)) (Common.validitySlots common)
  let funding = Map.elems (Map.fromList [(Utxo.input input, input) | input <- Common.spendingInputs common])
  boundedValue (foldMap (Output.value . Utxo.output) funding <> Common.sourceExtras params common)
  boundedValue (foldMap Output.value (Common.planOutputs common) <> Common.sinkExtras params common)
  mapM_
    bounded
    [ toInteger (Parameters.parameterKeyDeposit params),
      toInteger (Parameters.parameterPoolDeposit params),
      toInteger (fromMaybe 0 (Parameters.parameterGovernanceActionDeposit params)),
      toInteger (fromMaybe 0 (Parameters.parameterDrepDeposit params))
    ]
  where
    common = Plan.toPlan plan
    params = parameters config
    bounded amount = unless (amount >= 0 && amount <= toInteger (maxBound :: Int64)) (Left (InvalidBuildingRequest "Sub-transaction aggregate exceeds signed native bounds"))
    boundedValue value = mapM_ (bounded . snd) (Value.toList value)

validateBuilt :: Config -> SubTransaction -> Either Error ()
validateBuilt config transaction = do
  let params = parameters config
      fields = SubBody.fields (SubBody.toBody (Sub.body transaction))
      units = map Redeemer.executionUnits (Witnesses.redeemers (Witnesses.toWitnesses (Sub.witnesses transaction)))
  unless (toInteger (B.length (Sub.encodeCbor transaction)) <= toInteger (Parameters.parameterMaxTxSize params)) (Left (InvalidBuildingRequest "Sub-transaction exceeds maximum transaction size"))
  mapM_ (checkOutputSize (Parameters.parameterMaxValueSize params)) (Fields.fieldOutputs fields)
  case (units, Parameters.parameterMaxTxExUnits params) of
    ([], _) -> pure ()
    (_, Nothing) -> Left (InvalidBuildingRequest "Maximum transaction execution units are required")
    (_, Just cap) ->
      unless
        (sum (map (toInteger . Ex.memory) units) <= toInteger (Ex.memory cap) && sum (map (toInteger . Ex.steps) units) <= toInteger (Ex.steps cap))
        (Left (InvalidEvaluationResult "Sub-transaction exceeds maximum transaction execution units"))

checkOutputSize :: Maybe Word64 -> Output.Output -> Either Error ()
checkOutputSize Nothing _ = pure ()
checkOutputSize (Just limit) output =
  unless (toInteger (B.length (Cbor.encode encoding)) <= toInteger limit) (Left (InvalidBuildingRequest "Sub-transaction output exceeds maximum value size"))
  where
    value = Output.value output
    coin = E.encodeInteger (Value.quantity Ada value)
    assets = Value.toList (Value.difference value (Value.lovelace (Value.quantity Ada value)))
    encoding = if null assets then coin else E.encodeListLen 2 <> coin <> ValueCbor.encodeAssets value

-- | Test-only malformed instruction boundary. The runtime still encloses every
-- native owner and callback, including expected errors and asynchronous unwind.
runUnchecked :: Config -> Plan -> ByteString -> IO (Either Error ByteString)
runUnchecked config plan = runWithDispatch config (dispatch plan)

-- | Private dispatch injection for native callback-count and cleanup tests.
runWithDispatch :: Config -> Runtime.Dispatch -> ByteString -> IO (Either Error ByteString)
runWithDispatch config handler instructions = Runtime.withRuntime handler $ \runtime ->
  Runtime.withOperation runtime $ \context ->
    Runtime.withBytes (encodeConfig config) $ \configBytes configSize ->
      Runtime.withBytes instructions $ \planBytes planSize ->
        withResult (FFI.cBuild context configBytes configSize planBytes planSize)

encodeConfig :: Config -> ByteString
encodeConfig config =
  Cbor.encode
    ( E.encodeListLen 5
        <> E.encodeBytes (Snapshot.encodeSnapshot (parameters config))
        <> E.encodeWord (case networkId config of Testnet -> 0; Mainnet -> 1)
        <> E.encodeWord64 (Slots.zeroTime slots)
        <> E.encodeWord64 (Slots.zeroSlot slots)
        <> E.encodeWord64 (Slots.slotLength slots)
    )
  where
    slots = slotConfig config

-- Complete decoding, callback evaluation, payload encoding and native copying
-- happen inside the shared protected callback worker, forcing lazy failures.
dispatch :: Plan -> Runtime.Dispatch
dispatch plan operation bytes
  | operation /= 110 = pure (Left (UnsupportedOperation "Unknown sub-transaction deferred operation"))
  | otherwise = pure $ do
      (index, transaction, inputs) <- Cbor.decodeAs InvalidTransactionPlan parser bytes
      callback <- maybe (Left (NativeContractViolation "subTransaction.deferredIndex")) Right (Seq.lookup index (Common.deferredRedeemers (Plan.toPlan plan)))
      let canonical = sortOn Utxo.input inputs
          references = sort (Fields.fieldInputs (Body.bodyFields (Body.toBody (Tx.body transaction))))
      unless (map Utxo.input canonical == references && Body.fee (Body.toBody (Tx.body transaction)) == 0) (Left (NativeContractViolation "subTransaction.deferredInputs"))
      Data.toCbor <$> callback transaction canonical
  where
    parser = Cbor.array 3 ((,,) <$> D.decodeInt <*> Cbor.nested bytes Tx.decodeCbor <*> Cbor.list (Cbor.nested bytes Utxo.decodeCbor))

-- Initialize and bracket both transferred buffer obligations before calling C.
withResult :: (Ptr (Ptr Raw.Buffer) -> Ptr (Ptr Raw.Buffer) -> IO Status.NativeCode) -> IO (Either Error ByteString)
withResult call = alloca $ \output -> alloca $ \diagnostic ->
  bracket
    (poke output nullPtr >> poke diagnostic nullPtr)
    (\() -> Raw.cBufferRelease output >> Raw.cBufferRelease diagnostic)
    $ \() -> do
      status <- call output diagnostic
      if status == Status.success
        then peek output >>= Runtime.copyBuffer "subTransaction.build"
        else do
          pointer <- peek diagnostic
          if pointer == nullPtr
            then do
              checked <- Runtime.checkStatus "subTransaction.build" status
              pure (checked >> Left (NativeContractViolation "subTransaction.status"))
            else do
              copied <- Runtime.copyBuffer "subTransaction.diagnostic" pointer
              pure $ case copied of
                Left failure -> Left failure
                Right bytes -> Left (NativeError "subTransaction.build" (Code.fromNumber (toInteger status)) (Text.decodeUtf8With (\_ _ -> Just '\xfffd') bytes))
