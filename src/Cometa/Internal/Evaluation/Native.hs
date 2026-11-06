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

-- | Each invocation owns a distinct evaluator and parsed transaction snapshot.
-- Safe synchronous C return encloses every native owner, including cancellation.
module Cometa.Internal.Evaluation.Native (Config (..), evaluator, runUnchecked) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.Evaluation as Evaluation
import qualified Cometa.Internal.FFI.Native as Status
import qualified Cometa.Internal.FFI.NativeEvaluation as FFI
import qualified Cometa.Internal.FFI.Runtime as Raw
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | Native evaluator context. The schedule applies to every validity interval;
-- the protocol major selects language and builtin availability. Missing cost
-- models use the built-in per-version defaults. This is phase-2 execution,
-- not a check that the complete transaction is admissible on chain.
data Config = Config
  { -- | Constant-duration schedule, in Unix milliseconds.
    slotConfig :: !Slots.SlotConfig,
    -- | Ledger protocol major version (minor versions do not affect this VM).
    protocolMajor :: !Word64,
    -- | Ledger coefficients keyed by language id; empty selects VM defaults.
    costModels :: !Models.CostModels
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Construct an injectable evaluator. Every target evaluates all levels: a
-- failure in any level fails the request, and execution consumes a shared limit
-- of 100,000,000 memory units and 100,000,000,000 CPU steps. The target selects
-- only which level's budgets are returned. No transaction bytes are changed.
--
-- All spending and reference inputs at every level must resolve exactly once;
-- extra resolved UTxOs are allowed. Validity bounds must fit the supplied slot
-- schedule. No scripts returns empty budgets after these checks.
evaluator :: Config -> Evaluation.Evaluator
evaluator config = Evaluation.Evaluator $ \target transaction resolved -> case validate config target transaction resolved of
  Left failure -> pure (Left failure)
  Right () -> do
    result <- runUnchecked config target (Tx.encodeCbor transaction) (encodeUtxos resolved)
    pure $ do
      bytes <- result
      returned <- Redeemer.decodeCollectionCbor bytes
      Evaluation.budgetsFromRedeemers target transaction returned

validate :: Config -> Evaluation.Target -> Tx.Transaction -> [Utxo.Utxo] -> Either Error ()
validate config target transaction resolved = do
  Evaluation.validateRequest target transaction resolved
  traverse_ checkLevel levels
  where
    body = Body.toBody (Tx.body transaction)
    levels = Body.bodyFields body : maybe [] (map (SubBody.fields . SubBody.toBody . Sub.body)) (Body.bodySubTransactions body)
    available = Set.fromList (map Utxo.input resolved)
    checkLevel fields = do
      let required = Fields.fieldInputs fields ++ fromMaybe [] (Fields.fieldReferenceInputs fields)
      unless (all (`Set.member` available) required) (Left (InvalidEvaluationRequest "All spending and reference inputs must resolve"))
      traverse_ (Slots.slotToTime (slotConfig config)) (Fields.fieldInvalidBefore fields)
      traverse_ (Slots.slotToTime (slotConfig config)) (Fields.fieldInvalidAfter fields)

encodeUtxos :: [Utxo.Utxo] -> ByteString
encodeUtxos values = Cbor.encode (E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Utxo.encodeCbor) values)

-- | Internal malformed transport boundary for partial-cleanup tests.
runUnchecked :: Config -> Evaluation.Target -> ByteString -> ByteString -> IO (Either Error ByteString)
runUnchecked config target transaction resolved =
  Runtime.withBytes (Models.encodeCbor (costModels config)) $ \models modelsSize ->
    Runtime.withBytes transaction $ \tx txSize ->
      Runtime.withBytes resolved $ \utxos utxosSize ->
        withResult (FFI.cRun (Slots.zeroTime slots) (Slots.zeroSlot slots) (Slots.slotLength slots) (protocolMajor config) isSub index models modelsSize tx txSize utxos utxosSize)
  where
    slots = slotConfig config
    (isSub, index) = case target of
      Evaluation.TopLevel -> (0, 0)
      Evaluation.SubTransaction position -> (1, position)

-- Both slots initialize under mask and release after copying on every path.
withResult :: (Ptr (Ptr Raw.Buffer) -> Ptr (Ptr Raw.Buffer) -> IO Status.NativeCode) -> IO (Either Error ByteString)
withResult call = alloca $ \output -> alloca $ \diagnostic ->
  bracket
    (poke output nullPtr >> poke diagnostic nullPtr)
    (\() -> Raw.cBufferRelease output >> Raw.cBufferRelease diagnostic)
    $ \() -> do
      status <- call output diagnostic
      if status == Status.success
        then peek output >>= Runtime.copyBuffer "evaluation.native"
        else do
          pointer <- peek diagnostic
          if pointer == nullPtr
            then do
              checked <- Runtime.checkStatus "evaluation.native" status
              pure (checked >> Left (NativeContractViolation "evaluation.native.status"))
            else do
              copied <- Runtime.copyBuffer "evaluation.native.diagnostic" pointer
              pure $ case copied of
                Left failure -> Left failure
                Right bytes -> Left (NativeError "evaluation.native" (Code.fromNumber (toInteger status)) (Text.decodeUtf8With (\_ _ -> Just '\xfffd') bytes))
