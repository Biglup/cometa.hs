{-# LANGUAGE LambdaCase #-}
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

-- | Scoped standalone balancing, including stable spending-redeemer identity.
module Cometa.Internal.TransactionBalancing (balance, balanceWithRedeemers) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Term as Term
import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (Ada))
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Eval
import qualified Cometa.Internal.Balance as Balance
import qualified Cometa.Internal.BalancingScripts as Scripts
import qualified Cometa.Internal.BatchValidation as Batch
import qualified Cometa.Internal.Building as Building
import qualified Cometa.Internal.CoinSelection.Native as Selection
import qualified Cometa.Internal.Evaluation.Native as NativeEvaluation
import qualified Cometa.Internal.EvaluationNative as Evaluation
import qualified Cometa.Internal.FFI.TransactionBuilder as FFI
import qualified Cometa.Internal.ParameterSnapshot as Parameters
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionBuilder as Builder
import qualified Cometa.Internal.TransactionCbor as C
import qualified Cometa.PlutusData as Data
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as Ex
import qualified Cometa.Protocol.Parameters as P
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Plan (DeferredRedeemer)
import qualified Cometa.Transaction.Redeemer as Redeemer
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import Foreign.Ptr (nullPtr)

-- DEFINITIONS ----------------------------------------------------------------

-- | Balance an existing transaction with the same configuration used by
-- 'Cometa.Transaction.Builder.build'. Supply resolved spending, reference and
-- collateral inputs for every level; wallet candidates in the configuration may
-- also provide these snapshots. Every existing outer output is treated as a
-- payment, including previous change. The existing fee and configured minimum
-- fee are lower bounds. The imported network id is retained.
--
-- The result drops outer key/bootstrap signatures and retains signed nested
-- intent bodies and witnesses. Native serialization may normalize enclosing CBOR
-- array framing; it does not promise byte-for-byte transaction interchange.
-- Spending redeemers follow their original inputs when selection changes
-- input order. Script budgets, commitments, collateral and fees are recalculated.
-- Missing/conflicting inputs or invalid redeemer positions fail explicitly.
-- Callback exceptions and cancellation release scoped resources before propagating.
-- No provider queries, signing or submission occur; ledger acceptance is separate.
balance :: Builder.Config -> [Utxo] -> Transaction -> IO (Either Error Transaction)
balance config resolved = balanceWithRedeemers config resolved Map.empty

-- | Like 'balance', replacing selected outer redeemer payloads on every balancing
-- iteration. Keys identify purpose/index pairs in the ORIGINAL transaction; every
-- key must already have a witness redeemer. Spending associations follow their
-- original inputs even when their indices change. Other purposes retain their
-- existing body order. Callbacks receive the current draft and canonically ordered
-- resolved outer spending inputs. They may run repeatedly and must be deterministic.
-- Use "Cometa.Transaction.Deferred" to compose pure queries. Nested redeemers are
-- signed intent content and cannot be replaced by this operation.
balanceWithRedeemers :: Builder.Config -> [Utxo] -> Map Eval.RedeemerId DeferredRedeemer -> Transaction -> IO (Either Error Transaction)
balanceWithRedeemers config resolved callbacks original = runExceptT $ do
  snapshots <- except (validate config resolved callbacks original)
  ExceptT (preflight config snapshots original)
  prepared <- except (reserveScriptHash original)
  balancedDraft <- ExceptT (runBalance config snapshots callbacks prepared)
  models <- ExceptT (Scripts.usedCostModels (Builder.parameters config) snapshots balancedDraft)
  commitment <- ExceptT (Building.scriptDataHash models (Tx.witnesses balancedDraft))
  result <- except (setScriptHash commitment balancedDraft)
  except (validateResult config result)
  let evaluator = evaluatorFor config
  ExceptT (Batch.validateSubBudgets evaluator snapshots result)
  balanced <- ExceptT (Balance.isBalanced (Builder.parameters config) snapshots result)
  unless balanced (except (Left (NativeContractViolation "balancing.conservation")))
  pure result

-- | Resolve identities once; duplicates within a supplied snapshot are rejected.
validate :: Builder.Config -> [Utxo] -> Map Eval.RedeemerId DeferredRedeemer -> Transaction -> Either Error [Utxo]
validate config resolved callbacks transaction = do
  Parameters.validateNative (Builder.parameters config)
  mapM_ unique [resolved, Builder.availableUtxos config, Builder.collateralUtxos config]
  let allInputs = resolved <> Builder.availableUtxos config <> Builder.collateralUtxos config
      grouped = Map.fromListWith (<>) [(Utxo.input u, [u]) | u <- allInputs]
  unless (all agrees (Map.elems grouped)) (Left (InvalidBuildingRequest "Conflicting resolved input snapshots"))
  let snapshots = Map.fromList [(Utxo.input u, u) | u <- allInputs]
      body = Body.toBody (Tx.body transaction)
      fields = Body.bodyFields body
      subFields = maybe [] (map (SubBody.fields . SubBody.toBody . Sub.body)) (Body.bodySubTransactions body)
      required = concatMap references (fields : subFields) <> fromMaybe [] (Body.bodyCollateral body)
      redeemers = outerRedeemers transaction
      identifiers = map identifier redeemers
  unless (all (`Map.member` snapshots) required) (Left (InvalidBuildingRequest "A transaction input has no resolved UTxO"))
  unless (all uniqueReferences (fields : subFields)) (Left (InvalidBuildingRequest "Duplicate transaction input reference"))
  unless (Set.size (Set.fromList identifiers) == length identifiers) (Left (InvalidBuildingRequest "Duplicate redeemer purpose and index"))
  unless (all (`elem` identifiers) (Map.keys callbacks)) (Left (InvalidBuildingRequest "Deferred redeemer has no existing witness"))
  mapM_ (spendingInput fields) redeemers
  mapM_ (validatePurpose transaction) redeemers
  mapM_ (Slot.slotToTime (Builder.slotConfig config)) (maybe [] pure (Fields.fieldInvalidBefore fields) <> maybe [] pure (Fields.fieldInvalidAfter fields))
  pure (Map.elems snapshots)
  where
    unique values = unless (Set.size (Set.fromList (map Utxo.input values)) == length values) (Left (InvalidBuildingRequest "Duplicate resolved input snapshot"))
    agrees [] = True
    agrees (x : xs) = all (== x) xs
    uniqueReferences fields = let refs = Fields.fieldInputs fields in Set.size (Set.fromList refs) == length refs

-- | Spending indices refer to sorted original input identities, not list storage.
spendingInput :: Fields.Fields -> Redeemer.Redeemer -> Either Error (Maybe Input.Input)
spendingInput fields redeemer
  | Redeemer.purpose redeemer /= Redeemer.Spending = Right Nothing
  | otherwise = case dropInteger (Redeemer.index redeemer) (sort (Fields.fieldInputs fields)) of
      value : _ -> Right (Just value)
      [] -> Left (InvalidBuildingRequest "Spending redeemer index has no original input")
  where
    dropInteger index values
      | toInteger index >= toInteger (length values) = []
      | otherwise = drop (fromIntegral index) values

-- | Conservative bounds protect intermediate native fee and value arithmetic.
preflight :: Builder.Config -> [Utxo] -> Transaction -> IO (Either Error ())
preflight config snapshots transaction = runExceptT $ do
  let params = Builder.parameters config
      body = Body.toBody (Tx.body transaction)
      intents = fromMaybe [] (Body.bodySubTransactions body)
      allFields = Body.bodyFields body : map (SubBody.fields . SubBody.toBody . Sub.body) intents
      outputs = concatMap Fields.fieldOutputs allFields
      redeemers = outerRedeemers transaction <> concatMap (Witnesses.redeemers . Witnesses.toWitnesses . Sub.witnesses) intents
  outer <- ExceptT (Building.implicitCoin params transaction)
  nested <- traverse (ExceptT . Building.subTransactionImplicitCoin params) intents
  let implicit = outer : nested
      coin = sum [toInteger (Building.deposits x) + toInteger (Building.reclaimedDeposits x) + toInteger (Building.withdrawals x) | x <- implicit]
      spending = Set.fromList (concatMap Fields.fieldInputs allFields)
      referenced = Set.fromList (concatMap (fromMaybe [] . Fields.fieldReferenceInputs) allFields)
      authorized = Set.fromList (map Utxo.input (Builder.availableUtxos config))
      potential = filter (\u -> Utxo.input u `Set.member` spending || (Utxo.input u `Set.member` authorized && Utxo.input u `Set.notMember` referenced)) snapshots
      mint = concatMap (maybe [] (Value.toList . Fields.mintValue) . Fields.fieldMint) allFields
      consumed = Map.fromListWith (+) (concatMap (Value.toList . Output.value . Utxo.output) potential <> [(asset, amount) | (asset, amount) <- mint, amount > 0])
      produced = Map.fromListWith (+) (concatMap (Value.toList . Output.value) outputs <> [(asset, negate amount) | (asset, amount) <- mint, amount < 0])
      totals = Map.unionWith max consumed produced
      collateral = Map.fromListWith (+) (concatMap (Value.toList . Output.value . Utxo.output) (Builder.collateralUtxos config))
  except (mapM_ (bounded "Aggregate balance exceeds signed native bounds") (coin : Map.elems totals <> Map.elems collateral))
  except (bounded "Deposit exceeds signed native bounds" (toInteger (P.parameterKeyDeposit params) + toInteger (P.parameterPoolDeposit params)))
  let maximumSize = toInteger (P.parameterMaxTxSize params)
      extraKeys = toInteger (Builder.extraSigners config)
      snapshotSize = toInteger (B.length (Tx.encodeCbor transaction)) + sum [toInteger (B.length (Utxo.encodeCbor u)) | u <- snapshots]
      changeSize = (toInteger (length outputs) + 1) * (snapshotSize + 1) * (snapshotSize + toInteger (B.length (Address.toBytes (Builder.changeAddress config))) + 256)
      sizeBound = snapshotSize + changeSize + 1024 + 101 * (extraKeys + toInteger (length snapshots))
  except (unless (extraKeys <= maximumSize `div` 101) (Left (InvalidBuildingRequest "Additional signer witnesses exceed maximum transaction size")))
  except (bounded "Minimum Ada multiplication exceeds signed bounds" (toInteger (fromMaybe 0 (P.parameterAdaPerUtxoByte params)) * (maximumSize + 160)))
  except (unless (all ((<= maximumSize) . toInteger . B.length . Output.encodeCbor) outputs) (Left (InvalidBuildingRequest "Output exceeds maximum transaction size")))
  referenceFee <- if any (isJust . Output.referenceScript . Utxo.output) snapshots then ExceptT (Builder.pricedReferenceFee params (snapshots <> concatMap (const snapshots) intents)) else pure 0
  executionFee <-
    except $
      if null redeemers
        then Right 0
        else do
          prices <- maybe (Left (InvalidBuildingRequest "Script execution prices are required")) Right (P.parameterExecutionCosts params)
          cap <- maybe (Left (InvalidBuildingRequest "Maximum transaction execution units are required")) Right (P.parameterMaxTxExUnits params)
          pure (ceiling (fromIntegral (Ex.memory cap) * Rational.toRational (Prices.memoryPrice prices) + fromIntegral (Ex.steps cap) * Rational.toRational (Prices.stepPrice prices)))
  let feeBound = max (toInteger (max (Body.fee body) (Builder.minimumFee config))) (toInteger (P.parameterMinFeeB params) + toInteger (P.parameterMinFeeA params) * sizeBound + executionFee + toInteger referenceFee)
  except (bounded "Priced transaction exceeds signed balance bounds" (feeBound + coin + Map.findWithDefault 0 Ada totals))

bounded :: Text -> Integer -> Either Error ()
bounded message value = unless (value >= 0 && value <= toInteger (maxBound :: Int64)) (Left (InvalidBuildingRequest message))

-- | Run all callback owners under the same protected native operation.
runBalance :: Builder.Config -> [Utxo] -> Map Eval.RedeemerId DeferredRedeemer -> Transaction -> IO (Either Error Transaction)
runBalance config snapshots callbacks original =
  Runtime.withRuntime selection $ \selector ->
    Runtime.withRuntime (Evaluation.dispatch (Builder.checkedEvaluator config (evaluatorFor config)) Eval.TopLevel) $ \evaluator ->
      Runtime.withRuntime (deferredDispatch original callbacks) $ \deferred -> do
        result <- Runtime.withOperations [selector, evaluator, deferred] $ \case
          [selectionContext, evaluationContext, deferredContext] ->
            Runtime.withBytes (Builder.encodeConfig mempty configured) $ \configBytes configSize ->
              Runtime.withBytes (encodeRequest snapshots callbacks unsigned) $ \requestBytes requestSize ->
                Builder.withResultNamed "transaction.balance" (FFI.cBalance (if isJust (Builder.selector config) then selectionContext else nullPtr) evaluationContext deferredContext configBytes configSize requestBytes requestSize)
          _ -> pure (Left (NativeContractViolation "balancing.contexts"))
        pure $ do
          (bytes, keys) <- result
          transaction <- Tx.decodeCbor bytes
          let reserve = sum [180 + toInteger (B.length address) | address <- Set.toList (byronAddresses snapshots transaction)]
              size = toInteger (B.length bytes) + 101 * toInteger keys + reserve + 32
          unless (size <= toInteger (P.parameterMaxTxSize (Builder.parameters config))) (Left (InvalidBuildingRequest "Balanced transaction and witnesses exceed maximum size"))
          pure transaction
  where
    unsigned = Tx.setWitnesses (Witnesses.removeKeyWitnesses (Tx.witnesses original)) original
    body = Body.toBody (Tx.body original)
    fields = Body.bodyFields body
    reserved = references fields
    nestedReferences = maybe [] (concatMap (references . SubBody.fields . SubBody.toBody . Sub.body)) (Body.bodySubTransactions body)
    originalCollateral = fromMaybe [] (Body.bodyCollateral body)
    configured =
      config
        { Builder.availableUtxos = Map.elems (Map.fromList [(Utxo.input u, u) | u <- Builder.availableUtxos config <> filter (\u -> Utxo.input u `elem` nestedReferences) snapshots, Utxo.input u `notElem` reserved]),
          Builder.collateralUtxos = Map.elems (Map.fromList [(Utxo.input u, u) | u <- Builder.collateralUtxos config <> filter (\u -> Utxo.input u `elem` originalCollateral) snapshots])
        }
    selection = maybe (\_ _ -> pure (Left (NativeContractViolation "balancing.selector"))) Selection.dispatch (Builder.selector config)

-- | Native evaluator remains explicit IO, including inside native callback dispatch.
evaluatorFor :: Builder.Config -> Eval.Evaluator
evaluatorFor config = fromMaybe native (Builder.evaluator config)
  where
    Version.ProtocolVersion major _ = P.parameterProtocolVersion (Builder.parameters config)
    native = NativeEvaluation.evaluator (NativeEvaluation.Config (Builder.slotConfig config) major (fromMaybe Models.empty (P.parameterCostModels (Builder.parameters config))))

validateResult :: Builder.Config -> Transaction -> Either Error ()
validateResult config transaction = Builder.validateBudget config (map Redeemer.executionUnits redeemers)
  where
    redeemers = outerRedeemers transaction <> maybe [] (concatMap (Witnesses.redeemers . Witnesses.toWitnesses . Sub.witnesses)) (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))

references :: Fields.Fields -> [Input.Input]
references fields = Fields.fieldInputs fields <> fromMaybe [] (Fields.fieldReferenceInputs fields)

outerRedeemers :: Transaction -> [Redeemer.Redeemer]
outerRedeemers = Witnesses.redeemers . Witnesses.toWitnesses . Tx.witnesses

identifier :: Redeemer.Redeemer -> Eval.RedeemerId
identifier r = Eval.RedeemerId (Redeemer.purpose r) (Redeemer.index r)

encodeRequest :: [Utxo] -> Map Eval.RedeemerId DeferredRedeemer -> Transaction -> ByteString
encodeRequest snapshots callbacks transaction =
  C.encode $
    E.encodeListLen 4
      <> E.encodeBytes (Tx.encodeCbor transaction)
      <> utxos refs
      <> utxos spending
      <> E.encodeListLen (fromIntegral (length redeemers))
      <> foldMap entry redeemers
  where
    fields = Body.bodyFields (Body.toBody (Tx.body transaction))
    redeemers = outerRedeemers transaction
    refs = filter (\u -> Utxo.input u `elem` fromMaybe [] (Fields.fieldReferenceInputs fields)) snapshots
    spending = filter (\u -> Utxo.input u `elem` Fields.fieldInputs fields) snapshots
    utxos values = E.encodeListLen (fromIntegral (length values)) <> foldMap (C.raw . Utxo.encodeCbor) values
    entry r =
      E.encodeListLen 4
        <> E.encodeWord (fromIntegral (fromEnum (Redeemer.purpose r)))
        <> E.encodeWord32 (Redeemer.index r)
        <> E.encodeBytes (either (const mempty) (maybe mempty Input.encodeCbor) (spendingInput fields r))
        <> E.encodeBool (Map.member (identifier r) callbacks)

-- | Decode and fully force callback replies inside Runtime's exception boundary.
deferredDispatch :: Transaction -> Map Eval.RedeemerId DeferredRedeemer -> Runtime.Dispatch
deferredDispatch original callbacks operation bytes
  | operation /= 110 = pure (Left (UnsupportedOperation "Unknown balancing callback operation"))
  | otherwise = pure $ do
      (index, transaction, inputs) <- C.decodeAs InvalidBuildingRequest parser bytes
      ident <- maybe (Left (NativeContractViolation "balancing.callbackIndex")) Right (Map.lookup index identifiers)
      callback <- maybe (Left (NativeContractViolation "balancing.callback")) Right (Map.lookup ident callbacks)
      let selected = sortOn Utxo.input inputs
      unless (map Utxo.input selected == sort (Fields.fieldInputs (Body.bodyFields (Body.toBody (Tx.body transaction))))) (Left (NativeContractViolation "balancing.callbackInputs"))
      Data.toCbor <$> callback transaction selected
  where
    identifiers = Map.fromList (zip [0 :: Int ..] (map identifier (outerRedeemers original)))
    parser = C.array 3 ((,,) <$> D.decodeInt <*> C.nested bytes Tx.decodeCbor <*> C.list (C.nested bytes Utxo.decodeCbor))

-- | Inspect exact body collection lengths so imported zero mint groups still count.
validatePurpose :: Transaction -> Redeemer.Redeemer -> Either Error ()
validatePurpose transaction redeemer = do
  let bytes = Body.toCbor (Tx.body transaction)
      key = case Redeemer.purpose redeemer of
        Redeemer.Spending -> 0
        Redeemer.Minting -> 9
        Redeemer.Certifying -> 4
        Redeemer.Rewarding -> 5
        Redeemer.Voting -> 19
        Redeemer.Proposing -> 20
        Redeemer.Guarding -> 14
  fields <- C.decodeAs InvalidBuildingRequest (C.mapFields bytes) bytes
  count <- case Map.lookup key fields of
    Nothing -> Right 0
    Just encoded -> collectionLength <$> C.decodeAs InvalidBuildingRequest Term.decodeTerm encoded
  unless (toInteger (Redeemer.index redeemer) < toInteger count) (Left (InvalidBuildingRequest "Redeemer index has no body operation"))
  where
    collectionLength term = case term of
      Term.TTagged _ value -> collectionLength value
      Term.TList values -> length values
      Term.TListI values -> length values
      Term.TMap values -> length values
      Term.TMapI values -> length values
      _ -> 0

-- | Reserve exactly the final commitment's byte length before fee calculation.
reserveScriptHash :: Transaction -> Either Error Transaction
reserveScriptHash transaction
  | null (outerRedeemers transaction) && null (Witnesses.datums (Witnesses.toWitnesses (Tx.witnesses transaction))) = setScriptHash Nothing transaction
  | otherwise = Datum.hashFromBytes (B.replicate 32 0) >>= \hash -> setScriptHash (Just hash) transaction

-- | Replace only the unsigned outer body's commitment; preserve other field bytes.
setScriptHash :: Maybe Datum.Hash32 -> Transaction -> Either Error Transaction
setScriptHash commitment transaction = do
  let bytes = Body.toCbor (Tx.body transaction)
  fields <- C.decodeAs InvalidBuildingRequest (C.mapFields bytes) bytes
  let updated = case commitment of
        Nothing -> Map.delete 11 fields
        Just hash -> Map.insert 11 (C.encode (E.encodeBytes (Datum.hashBytes hash))) fields
      encoded = C.encode (E.encodeMapLen (fromIntegral (Map.size updated)) <> foldMap (\(key, value) -> E.encodeWord64 key <> C.raw value) (Map.toAscList updated))
  replacement <- Body.decodeCbor encoded
  pure (Tx.setBody replacement transaction)

-- | Only actual spending/collateral Byron addresses need bootstrap reserves.
byronAddresses :: [Utxo] -> Transaction -> Set.Set ByteString
byronAddresses snapshots transaction =
  Set.fromList
    [ Address.toBytes address
    | u <- snapshots,
      Utxo.input u `elem` used,
      let address = Output.address (Utxo.output u),
      case address of Address.ByronAddress _ -> True; _ -> False
    ]
  where
    body = Body.toBody (Tx.body transaction)
    used = Fields.fieldInputs (Body.bodyFields body) <> fromMaybe [] (Body.bodyCollateral body)
