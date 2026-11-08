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
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Balance a complete pure transaction plan using explicit protocol and wallet
-- snapshots. Build returns a fresh unsigned transaction; signing and submission
-- are separate operations. Inject selection or evaluation with ordinary records.
--
-- @
-- buildPayment params slots change funds output =
--   build (defaultConfig params slots change) {availableUtxos = funds}
--     (Plan.payTo output)
-- @
module Cometa.Internal.TransactionBuilder (Config (..), defaultConfig, build, encodeConfig, withResult, withResultNamed, checkedEvaluator, validateBudget, pricedReferenceFee) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Address (Address)
import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (Ada))
import Cometa.CoinSelection (Selector)
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import Cometa.Evaluation (Evaluator, Target (TopLevel))
import qualified Cometa.Evaluation as Eval
import qualified Cometa.Internal.BatchValidation as Batch
import qualified Cometa.Internal.Building as Building
import qualified Cometa.Internal.CoinSelection.Native as Selection
import qualified Cometa.Internal.Evaluation.Native as NativeEvaluation
import qualified Cometa.Internal.EvaluationNative as Evaluation
import qualified Cometa.Internal.FFI.Native as Native
import qualified Cometa.Internal.FFI.Runtime as Raw
import qualified Cometa.Internal.FFI.TransactionBuilder as FFI
import qualified Cometa.Internal.ParameterSnapshot as Parameters
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as C
import qualified Cometa.Internal.TransactionPlan as Plan
import qualified Cometa.Internal.TransactionValue as ValueCbor
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as Ex
import Cometa.Protocol.Parameters (Parameters)
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import Cometa.SlotConfig (SlotConfig)
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Transaction
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Plan (Plan)
import qualified Cometa.Transaction.Redeemer as Redeemer
import Cometa.Transaction.Utxo (Utxo)
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
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | Explicit context for one build. Snapshots must describe the same ledger
-- state. Callback records can be invoked repeatedly as balancing converges.
data Config = Config
  { -- | Complete protocol snapshot used for fees, limits and script costs.
    parameters :: Parameters,
    -- | Network slot/time conversion used by script evaluation.
    slotConfig :: SlotConfig,
    -- | Address receiving change; its network also sets the body network id.
    changeAddress :: Address,
    -- | Wallet outputs eligible for additional spending selection.
    availableUtxos :: [Utxo],
    -- | Outputs eligible for Plutus collateral selection.
    collateralUtxos :: [Utxo],
    -- | Optional collateral return destination; defaults to the change address.
    collateralChangeAddress :: Maybe Address,
    -- | Optional selector; absence uses the native random-improve selector.
    selector :: Maybe Selector,
    -- | Optional evaluator; absence uses the built-in evaluator. For batches,
    -- the evaluator must also support subtransaction targets to verify that
    -- signed execution budgets cover the final batch context.
    evaluator :: Maybe Evaluator,
    -- | Lower bound on the fee in lovelace; zero permits ordinary calculation.
    minimumFee :: Word64,
    -- | Additional key witnesses included in fee size estimation.
    extraSigners :: Word64
  }

-- DEFINITIONS ----------------------------------------------------------------

-- | No eligible wallet/collateral outputs, no injected callbacks, and zero fee
-- floor or additional witnesses. Supply wallet snapshots before building.
defaultConfig :: Parameters -> SlotConfig -> Address -> Config
defaultConfig params slots change = Config params slots change [] [] Nothing Nothing Nothing 0 0

-- | Validate requirements, run balancing and copy the completed unsigned
-- transaction. Expected failures return once here, including original callback
-- errors. Callback exceptions and asynchronous cancellation unwind all native
-- work before propagating. No chain queries, signing or submission occur.
build :: Config -> Plan -> IO (Either Error Transaction)
build config plan = case validate config plan of
  Left failure -> pure (Left failure)
  Right () -> do
    fees <- validateFees config plan
    case fees of
      Left failure -> pure (Left failure)
      Right () -> buildNative config plan

buildNative :: Config -> Plan -> IO (Either Error Transaction)
buildNative config plan =
  Runtime.withRuntime selectDispatch $ \selection ->
    Runtime.withRuntime evaluateDispatch $ \evaluation ->
      Runtime.withRuntime (deferredDispatch plan) $ \deferred -> do
        result <- Runtime.withOperations [selection, evaluation, deferred] $ \case
          [selectContext, evaluateContext, deferredContext] ->
            Runtime.withBytes (encodeConfig plan config) $ \configBytes configSize ->
              Runtime.withBytes (Plan.encodePlan (fromMaybe 0 (P.parameterGovernanceActionDeposit (parameters config))) plan) $ \planBytes planSize ->
                withResult
                  ( FFI.cBuild
                      (if isJust (selector config) then selectContext else nullPtr)
                      (if isJust (evaluator config) then evaluateContext else nullPtr)
                      deferredContext
                      configBytes
                      configSize
                      planBytes
                      planSize
                  )
          _ -> pure (Left (NativeContractViolation "builder.contexts"))
        case result >>= decodeBuilt of
          Left failure -> pure (Left failure)
          Right transaction -> do
            checked <- Batch.validateSubBudgets (fromMaybe nativeEvaluator (evaluator config)) resolved transaction
            pure (transaction <$ checked)
  where
    decodeBuilt (bytes, keyCount) = do
      transaction <- Transaction.decodeCbor bytes
      validateBuilt config plan keyCount transaction
      pure transaction
    resolved = Map.elems (Map.fromList [(Utxo.input input, input) | input <- availableUtxos config <> collateralUtxos config <> Plan.resolvedInputs plan])
    nativeEvaluator =
      let Version.ProtocolVersion major _ = P.parameterProtocolVersion (parameters config)
       in NativeEvaluation.evaluator (NativeEvaluation.Config (slotConfig config) major (fromMaybe Models.empty (P.parameterCostModels (parameters config))))
    selectDispatch = maybe unavailable Selection.dispatch (selector config)
    evaluateDispatch = maybe unavailable (\backend -> Evaluation.dispatch (checkedEvaluator config backend) TopLevel) (evaluator config)
    unavailable _ _ = pure (Left (NativeContractViolation "builder.unconfiguredCallback"))

validate :: Config -> Plan -> Either Error ()
validate config plan = do
  Plan.validatePlan plan
  Plan.validateTopLevel plan
  mapM_
    (checkSubOutputSize (P.parameterMaxValueSize (parameters config)))
    [output | (transaction, _) <- Plan.subTransactions plan, output <- Fields.fieldOutputs (SubBody.fields (SubBody.toBody (Sub.body transaction)))]
  mapM_ (Slot.slotToTime (slotConfig config)) (Plan.validitySlots plan)
  Parameters.validateNative (parameters config)
  consistent (availableUtxos config <> collateralUtxos config <> Plan.resolvedInputs plan)
  unique (availableUtxos config)
  unique (collateralUtxos config)
  bounded "Fee exceeds signed native balance bounds" (toInteger (minimumFee config))
  let funds = Map.elems (Map.fromList [(Utxo.input u, u) | u <- eligible plan (availableUtxos config) <> Plan.spendingInputs plan])
      inputValue = foldMap (Output.value . Utxo.output) funds
      outputValue = foldMap Output.value (Plan.planOutputs plan)
      collateralValue = foldMap (Output.value . Utxo.output) (eligible plan (collateralUtxos config))
      witnessBytes values =
        sum
          [ case Output.address (Utxo.output u) of
              Address.ByronAddress _ -> 180 + toInteger (B.length (Address.toBytes (Output.address (Utxo.output u))))
              _ -> 101
          | u <- values
          ]
      potentialWitnessBytes = witnessBytes (funds <> collateralUtxos config) + 101 * (toInteger (extraSigners config) + Plan.witnessCount plan) + 32
      maximumFee =
        max
          (toInteger (minimumFee config))
          (toInteger (P.parameterMinFeeA (parameters config)) * toInteger (P.parameterMaxTxSize (parameters config)) + toInteger (P.parameterMinFeeB (parameters config)))
  bounded
    "Potential native witness fee exceeds signed balance bounds"
    (maximumFee + potentialWitnessBytes * toInteger (P.parameterMinFeeA (parameters config)))
  bounded "Maximum linear transaction fee exceeds signed native balance bounds" maximumFee
  case P.parameterAdaPerUtxoByte (parameters config) of
    Nothing -> pure ()
    Just price ->
      bounded
        "Minimum Ada multiplication exceeds signed bounds"
        (toInteger price * (160 + toInteger (P.parameterMaxTxSize (parameters config))))
  boundedValue (inputValue <> Plan.sourceExtras (parameters config) plan)
  boundedValue (outputValue <> Plan.sinkExtras (parameters config) plan <> Value.lovelace maximumFee)
  boundedValue collateralValue
  bounded "Stake key deposit exceeds signed native bounds" (toInteger (P.parameterKeyDeposit (parameters config)))
  bounded "Governance proposal deposit exceeds signed native bounds" (toInteger (fromMaybe 0 (P.parameterGovernanceActionDeposit (parameters config))))
  bounded "Pool deposit exceeds signed native bounds" (toInteger (P.parameterPoolDeposit (parameters config)))
  unless
    (toInteger (extraSigners config) <= toInteger (P.parameterMaxTxSize (parameters config)) `div` 101)
    (Left (InvalidBuildingRequest "Additional signer witnesses exceed maximum transaction size"))
  where
    bounded message n = unless (n >= 0 && n <= toInteger (maxBound :: Int64)) (Left (InvalidBuildingRequest message))
    boundedValue value = mapM_ (bounded "Aggregate native balance exceeds signed bounds" . snd) (Value.toList value)
    unique values =
      unless
        (Set.size (Set.fromList (map Utxo.input values)) == length values)
        (Left (InvalidBuildingRequest "Duplicate input reference in wallet snapshot"))
    consistent values =
      unless
        (all (\a -> all (\b -> Utxo.input a /= Utxo.input b || a == b) values) values)
        (Left (InvalidBuildingRequest "Conflicting snapshots for one wallet input"))

-- Fee preflight includes every potentially selected reference script. The native
-- VM uses one shared fixed100m/100b memory/CPU ceiling (pinned native evaluator
-- lines128/134 and2249); injected budgets are capped by the supplied protocol.
validateFees :: Config -> Plan -> IO (Either Error ())
validateFees config plan = do
  let possible = Map.elems (Map.fromList [(Utxo.input u, u) | u <- eligible plan (availableUtxos config) <> Plan.outerResolvedInputs plan])
      subPriced = concatMap pricedSub (Plan.subTransactions plan)
      allPriced = possible <> subPriced
      hasReferenceScript = any (isJust . Output.referenceScript . Utxo.output) allPriced
  reference <- if hasReferenceScript then pricedReferenceFee (parameters config) allPriced else pure (Right 0)
  pure $ do
    referenceFee <- reference
    executionFee <- executionLimitFee config plan
    let params = parameters config
        witnessBytes =
          101 * (toInteger (extraSigners config) + Plan.witnessCount plan)
            + sum
              [ case Output.address (Utxo.output u) of
                  Address.ByronAddress _ -> 180 + toInteger (B.length (Address.toBytes (Output.address (Utxo.output u))))
                  _ -> 101
              | u <- possible <> collateralUtxos config
              ]
            + 32
        -- A source/plan byte bounds the count of distinct assets it can
        -- encode. Native change may repeat all incidental assets for every
        -- output hint, then split oversized values. Bound those two counts by
        -- (hints+1)*(snapshotBytes+1), and each resulting output by the full
        -- asset snapshot plus address and map/coin/script framing allowance.
        snapshotBytes =
          toInteger (B.length (Plan.encodePlan (fromMaybe 0 (P.parameterGovernanceActionDeposit (parameters config))) plan))
            + sum [toInteger (B.length (Utxo.encodeCbor u)) | u <- possible <> collateralUtxos config]
        changeCount = (toInteger (length (Plan.planOutputs plan)) + 1) * (snapshotBytes + 1)
        changeBytes = changeCount * (snapshotBytes + toInteger (B.length (Address.toBytes (changeAddress config))) + 256)
        sizeBound = snapshotBytes + changeBytes + 1024 + witnessBytes
        linearFee = toInteger (P.parameterMinFeeB params) + toInteger (P.parameterMinFeeA params) * sizeBound
        fee = max (toInteger (minimumFee config)) (linearFee + executionFee + toInteger referenceFee)
        sink = foldMap Output.value (Plan.planOutputs plan) <> Plan.sinkExtras params plan <> Value.lovelace fee
    unless
      (fee <= toInteger (maxBound :: Int64) && all ((<= toInteger (maxBound :: Int64)) . snd) (Value.toList sink))
      (Left (InvalidBuildingRequest "Complete priced fee or target exceeds signed native bounds"))

executionLimitFee :: Config -> Plan -> Either Error Integer
executionLimitFee config plan
  | not (Plan.requiresEvaluation plan) = Right 0
  | otherwise = do
      prices <- maybe (Left (InvalidBuildingRequest "Script execution prices are required")) Right (P.parameterExecutionCosts (parameters config))
      cap <- case evaluator config of
        Nothing -> Right (Ex.ExUnits 100000000 100000000000)
        Just _ -> maybe (Left (InvalidBuildingRequest "Maximum transaction execution units are required")) Right (P.parameterMaxTxExUnits (parameters config))
      pure
        ( ceiling
            ( fromIntegral (Ex.memory cap) * Rational.toRational (Prices.memoryPrice prices)
                + fromIntegral (Ex.steps cap) * Rational.toRational (Prices.stepPrice prices)
            )
        )

checkedEvaluator :: Config -> Evaluator -> Evaluator
checkedEvaluator config backend = Eval.Evaluator $ \target transaction inputs -> do
  result <- Eval.evaluate backend target transaction inputs
  pure $ do
    computed <- result
    validateBudget config (map snd (Eval.budgets computed))
    pure computed

validateBudget :: Config -> [Ex.ExUnits] -> Either Error ()
validateBudget config units = case (units, P.parameterMaxTxExUnits (parameters config)) of
  ([], _) -> pure ()
  (_, Nothing) -> Left (InvalidBuildingRequest "Maximum transaction execution units are required")
  (_, Just cap) ->
    unless
      ( sum (map (toInteger . Ex.memory) units) <= toInteger (Ex.memory cap)
          && sum (map (toInteger . Ex.steps) units) <= toInteger (Ex.steps cap)
      )
      (Left (InvalidEvaluationResult "Evaluation exceeds maximum transaction execution units"))

validateBuilt :: Config -> Plan -> Word64 -> Transaction -> Either Error ()
validateBuilt config plan keyCount transaction = do
  let body = Body.toBody (Transaction.body transaction)
      fields = Body.bodyFields body
      used = Fields.fieldInputs fields <> fromMaybe [] (Body.bodyCollateral body)
      sourceMap = Map.fromList [(Utxo.input u, u) | u <- availableUtxos config <> collateralUtxos config <> Plan.resolvedInputs plan]
      selectedInputs = [u | reference <- used, Just u <- [Map.lookup reference sourceMap]]
      byronAddresses =
        Set.fromList
          [ Address.toBytes destination
          | u <- selectedInputs,
            let destination = Output.address (Utxo.output u),
            case destination of Address.ByronAddress _ -> True; _ -> False
          ]
      reserve = 101 * toInteger keyCount + sum [180 + toInteger (B.length bytes) | bytes <- Set.toList byronAddresses] + 32
      size = toInteger (B.length (Transaction.encodeCbor transaction)) + reserve
  validateBudget
    config
    ( map Redeemer.executionUnits (Witnesses.redeemers (Witnesses.toWitnesses (Transaction.witnesses transaction)))
        <> concatMap (map Redeemer.executionUnits . Witnesses.redeemers . Witnesses.toWitnesses . Sub.witnesses . fst) (Plan.subTransactions plan)
    )
  unless
    (size <= toInteger (P.parameterMaxTxSize (parameters config)))
    (Left (InvalidBuildingRequest "Transaction and required witness reserve exceed maximum transaction size"))

encodeConfig :: Plan -> Config -> ByteString
encodeConfig plan config =
  C.encode
    ( E.encodeListLen 10
        <> mconcat
          [ E.encodeBytes (Parameters.encodeSnapshot (parameters config)),
            E.encodeBytes (Address.toBytes (changeAddress config)),
            utxos (filter (\u -> Utxo.input u `notElem` map Utxo.input (Plan.spendingInputs plan)) (eligible plan (availableUtxos config))),
            utxos (eligible plan (collateralUtxos config)),
            E.encodeBytes (maybe mempty Address.toBytes (collateralChangeAddress config)),
            E.encodeWord64 (minimumFee config),
            E.encodeWord64 (extraSigners config),
            E.encodeWord64 (Slot.zeroTime (slotConfig config)),
            E.encodeWord64 (Slot.zeroSlot (slotConfig config)),
            E.encodeWord64 (Slot.slotLength (slotConfig config))
          ]
    )
  where
    utxos values = E.encodeListLen (fromIntegral (length values)) <> foldMap (C.raw . Utxo.encodeCbor) values

-- | Initialize both owner slots before C; diagnostics are copied before release,
-- including failures. Runtime preserves original typed callback errors on unwind.
withResult :: (Ptr (Ptr Raw.Buffer) -> Ptr (Ptr Raw.Buffer) -> Ptr Word64 -> IO Native.NativeCode) -> IO (Either Error (ByteString, Word64))
withResult = withResultNamed "builder.build"

-- | Preserve operation-specific diagnostic names while sharing buffer ownership.
withResultNamed :: Text -> (Ptr (Ptr Raw.Buffer) -> Ptr (Ptr Raw.Buffer) -> Ptr Word64 -> IO Native.NativeCode) -> IO (Either Error (ByteString, Word64))
withResultNamed operation call = alloca $ \output -> alloca $ \diagnostic -> alloca $ \keyCount ->
  bracket
    (poke output nullPtr >> poke diagnostic nullPtr >> poke keyCount 0)
    (\() -> Raw.cBufferRelease output >> Raw.cBufferRelease diagnostic)
    $ \() -> do
      status <- call output diagnostic keyCount
      if status == Native.success
        then do
          bytes <- peek output >>= Runtime.copyBuffer operation
          count <- peek keyCount
          pure ((,count) <$> bytes)
        else do
          pointer <- peek diagnostic
          if pointer == nullPtr
            then do
              checked <- Runtime.checkStatus operation status
              pure (checked >> Left (NativeContractViolation "builder.status"))
            else do
              copied <- Runtime.copyBuffer "builder.diagnostic" pointer
              pure $ case copied of
                Left failure -> Left failure
                Right bytes -> Left (NativeError operation (Code.fromNumber (toInteger status)) (Text.decodeUtf8With (\_ _ -> Just '\xfffd') bytes))

-- The runtime protects decoding, pure callback evaluation, complete reply
-- encoding and native copying together. Lazy failures therefore unwind through
-- the ordinary callback exception/cancellation boundary before C sees success.
deferredDispatch :: Plan -> Runtime.Dispatch
deferredDispatch plan operation bytes
  | operation /= 110 = pure (Left (UnsupportedOperation "Unknown deferred redeemer callback operation"))
  | otherwise = pure $ do
      (index, transaction, inputs) <- C.decodeAs InvalidTransactionPlan parser bytes
      callback <- maybe (Left (NativeContractViolation "builder.deferredIndex")) Right (Seq.lookup index (Plan.deferredRedeemers plan))
      -- The pinned native balancer supplies selection order despite its header
      -- promising canonical order. Normalize the owned snapshot and verify that
      -- every spending input resolves exactly once before invoking user code.
      let canonical = sortOn Utxo.input inputs
          references = sort (Fields.fieldInputs (Body.bodyFields (Body.toBody (Transaction.body transaction))))
      unless (map Utxo.input canonical == references) (Left (NativeContractViolation "builder.deferredInputs"))
      Data.toCbor <$> callback transaction canonical
  where
    parser = C.array 3 ((,,) <$> D.decodeInt <*> C.nested bytes Transaction.decodeCbor <*> C.list (C.nested bytes Utxo.decodeCbor))

-- A subtransaction reserves both its spending and reference inputs against
-- parent spending/collateral selection. Explicit parent reference inputs remain
-- independently priced; each level counts its own referenced scripts once.
eligible :: Plan -> [Utxo] -> [Utxo]
eligible plan = filter (\input -> Utxo.input input `notElem` Plan.reservedInputs plan)

pricedSub :: (Sub.SubTransaction, [Utxo]) -> [Utxo]
pricedSub (transaction, resolved) =
  let fields = SubBody.fields (SubBody.toBody (Sub.body transaction))
      references = Fields.fieldInputs fields <> fromMaybe [] (Fields.fieldReferenceInputs fields)
   in filter (\input -> Utxo.input input `elem` references) resolved

-- The public standalone reference-fee helper rejects duplicate identities, but
-- batch pricing deliberately counts a shared script once for each level using
-- it. The private native transport accepts that multiplicity and applies the
-- pricing tiers to the complete byte total, avoiding a sum of underpriced tiers.
pricedReferenceFee :: Parameters -> [Utxo] -> IO (Either Error Word64)
pricedReferenceFee params inputs = case P.parameterRefScriptCostPerByte params of
  Nothing -> pure (Left (InvalidBuildingRequest "Reference script byte price is required"))
  Just _ -> do
    result <-
      Building.runUnchecked
        1
        ( C.encode
            ( E.encodeListLen 2
                <> C.raw (Parameters.encodeSnapshot params)
                <> E.encodeListLen (fromIntegral (length inputs))
                <> foldMap (C.raw . Utxo.encodeCbor) inputs
            )
        )
    pure (result >>= C.decodeAs InvalidBuildingRequest D.decodeWord64)

-- Imported/signed subtransactions bypass local building, so validate their
-- immutable output values against the same configured limit before attachment.
checkSubOutputSize :: Maybe Word64 -> Output.Output -> Either Error ()
checkSubOutputSize Nothing _ = pure ()
checkSubOutputSize (Just limit) output =
  unless
    (toInteger (B.length (C.encode encoding)) <= toInteger limit)
    (Left (InvalidBuildingRequest "Attached subtransaction output exceeds maximum value size"))
  where
    value = Output.value output
    coin = E.encodeInteger (Value.quantity Ada value)
    assets = Value.toList (Value.difference value (Value.lovelace (Value.quantity Ada value)))
    encoding = if null assets then coin else E.encodeListLen 2 <> coin <> ValueCbor.encodeAssets value
