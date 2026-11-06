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

-- | Private native evaluator injection. Public direct Haskell evaluation avoids
-- a C roundtrip. Runtime scopes root registrations through final callback unwind;
-- no native context handle appears in the public evaluator record.
module Cometa.Internal.EvaluationNative
  ( NativeEvaluator,
    withEvaluator,
    withProviderEvaluator,
    withDispatch,
    withRetained,
    close,
    evaluate,
    evaluateRepeated,
    dispatch,
    runUnchecked,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Evaluation as Evaluation
import qualified Cometa.Internal.FFI.Evaluation as FFI
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import Data.ByteString (ByteString)
import Data.Word (Word32)

-- TYPES ----------------------------------------------------------------------

data NativeEvaluator = NativeEvaluator !Runtime.Runtime !Evaluation.Target !Bool

-- DEFINITIONS ----------------------------------------------------------------

withEvaluator :: Evaluation.Evaluator -> Evaluation.Target -> (NativeEvaluator -> IO (Either Error a)) -> IO (Either Error a)
withEvaluator evaluator target = withDispatch target (dispatch evaluator target)

-- | Real provider-backed native factory, bound to the provider's top-level ABI.
withProviderEvaluator :: Evaluation.Evaluator -> (NativeEvaluator -> IO (Either Error a)) -> IO (Either Error a)
withProviderEvaluator evaluator action = Runtime.withRuntime route $ \runtime -> action (NativeEvaluator runtime Evaluation.TopLevel True)
  where
    route operation = dispatch evaluator Evaluation.TopLevel (if operation == 9 then 100 else operation)

-- | Private malformed-transport injection for ownership tests.
withDispatch :: Evaluation.Target -> Runtime.Dispatch -> (NativeEvaluator -> IO (Either Error a)) -> IO (Either Error a)
withDispatch target handler action = Runtime.withRuntime handler $ \runtime -> action (NativeEvaluator runtime target False)

withRetained :: NativeEvaluator -> (NativeEvaluator -> IO (Either Error a)) -> IO (Either Error a)
withRetained (NativeEvaluator runtime target provider) action = Runtime.withRetained runtime $ \alias -> action (NativeEvaluator alias target provider)

close :: NativeEvaluator -> IO (Either Error ())
close (NativeEvaluator runtime _ _) = Runtime.close runtime

evaluate :: NativeEvaluator -> Tx.Transaction -> [Utxo.Utxo] -> IO (Either Error Evaluation.Budgets)
evaluate = evaluateRepeated 1

evaluateRepeated :: Word32 -> NativeEvaluator -> Tx.Transaction -> [Utxo.Utxo] -> IO (Either Error Evaluation.Budgets)
evaluateRepeated count handle@(NativeEvaluator _ target _) transaction resolved = case Evaluation.validateRequest target transaction resolved of
  Left failure -> pure (Left failure)
  Right () -> do
    result <- runUnchecked count handle (Tx.encodeCbor transaction) (encodeUtxos resolved)
    pure $ do
      bytes <- result
      redeemers <- Redeemer.decodeCollectionCbor bytes
      Evaluation.budgetsFromRedeemers target transaction redeemers

-- | Test-only malformed/reply and partial-cleanup injection boundary. Runtime
-- activation still encloses all native work and callbacks.
runUnchecked :: Word32 -> NativeEvaluator -> ByteString -> ByteString -> IO (Either Error ByteString)
runUnchecked count (NativeEvaluator runtime _ provider) transaction resolved = Runtime.withOperation runtime $ \context ->
  Runtime.withBytes transaction $ \txBytes txSize ->
    Runtime.withBytes resolved $ \utxoBytes utxoSize ->
      Runtime.withOwnedBuffer "evaluation.evaluate" ((if provider then FFI.cRunProvider else FFI.cRun) context txBytes txSize utxoBytes utxoSize count)

-- | Native serialization snapshots the complete native transaction. Its outer
-- frame may be definite even when the original input used an indefinite array;
-- existing exact body, script, argument and witness child encodings are retained.
dispatch :: Evaluation.Evaluator -> Evaluation.Target -> Runtime.Dispatch
dispatch evaluator target operation input
  | operation /= 100 = pure (Left (UnsupportedOperation "Unknown evaluator callback operation"))
  | otherwise = case decodeRequest input of
      Left failure -> pure (Left failure)
      Right (transaction, resolved) -> do
        result <- Evaluation.evaluate evaluator target transaction resolved
        pure $ do
          computed <- result
          values <- Evaluation.checkedRedeemers target transaction computed
          Redeemer.encodeCollectionCbor values

encodeUtxos :: [Utxo.Utxo] -> ByteString
encodeUtxos values = Cbor.encode (E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Utxo.encodeCbor) values)

decodeRequest :: ByteString -> Either Error (Tx.Transaction, [Utxo.Utxo])
decodeRequest bytes = Cbor.decodeAs InvalidEvaluationRequest parser bytes
  where
    parser = Cbor.array 2 ((,) <$> Cbor.nested bytes Tx.decodeCbor <*> Cbor.list (Cbor.nested bytes Utxo.decodeCbor))
