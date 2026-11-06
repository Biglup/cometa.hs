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
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Typed provider/native callback translation. Scoped adapters own their runtime;
-- direct public records have no native lifetime. Private round-trip operations
-- exercise actual cardano_provider_* dispatch, not a Haskell-only echo.
module Cometa.Internal.ProviderRuntime (Adapter, withProvider, runtime, nativeProvider, dispatch, withNative) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import Cometa.AssetId (AssetId (..))
import qualified Cometa.AssetName as AssetName
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Internal.Evaluation as Eval
import qualified Cometa.Internal.FFI.ProviderRuntime as FFI
import qualified Cometa.Internal.ParameterSnapshot as Parameters
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as C
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import Cometa.Provider (Provider (..))
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TxId
import Control.Exception (bracket)
import Control.Monad ((>=>))
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word32)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

data Adapter = Adapter Runtime.Runtime !Text !ByteString !Word32

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate metadata before adopting any Haskell callback registration.
withProvider :: Provider -> (Adapter -> IO (Either Error a)) -> IO (Either Error a)
withProvider provider action
  | B.length bytes > 255 || Text.any (== '\0') (name provider) = pure (Left (InvalidCallbackResult "Provider name must be at most 255 UTF-8 bytes without NUL"))
  | otherwise = Runtime.withRuntime (dispatch provider) $ \owner -> action (Adapter owner (name provider) bytes (networkMagic provider))
  where
    bytes = Text.encodeUtf8 (name provider)

-- | The runtime is available only for internal grouped operation activation.
runtime :: Adapter -> Runtime.Runtime
runtime (Adapter owner _ _ _) = owner

-- | Scope one actual native provider under this adapter's operation state.
-- The continuation borrows it; no returned native reference may escape the scope.
withNative :: Adapter -> (Ptr FFI.NativeProvider -> IO (Either Error a)) -> IO (Either Error a)
withNative (Adapter owner _ backendName magic) action = Runtime.withOperation owner $ \context ->
  Runtime.withBytes backendName $ \nameBytes nameSize -> alloca $ \slot ->
    bracket (poke slot nullPtr >> pure slot) FFI.cRelease $ \output -> do
      result <- FFI.cNew context nameBytes nameSize magic output >>= Runtime.checkStatus "provider.acquire"
      case result of
        Left failure -> pure (Left failure)
        Right () -> do
          pointer <- peek output
          if pointer == nullPtr then pure (Left (NativeContractViolation "provider.acquire")) else action pointer

call :: Adapter -> Word32 -> ByteString -> IO (Either Error ByteString)
call (Adapter owner _ backendName magic) operation bytes = Runtime.withOperation owner $ \context ->
  Runtime.withBytes backendName $ \nameBytes nameSize -> Runtime.withBytes bytes $ \input size ->
    Runtime.withOwnedBuffer "provider.nativeDispatch" (FFI.cCall context nameBytes nameSize magic operation input size)

-- | Re-express every callback through actual typed native provider methods.
-- Pure request decoders reject trailing bytes. Native serialization can normalize
-- outer framing; exact transaction-body bytes remain untouched.
nativeProvider :: Adapter -> Provider
nativeProvider adapter@(Adapter _ backendName _ magic) =
  Provider
    { name = backendName,
      networkMagic = magic,
      protocolParameters = do
        result <- call adapter 0 (C.encode (E.encodeListLen 0))
        pure (result >>= Parameters.decodeSnapshot),
      utxosAt = \address -> decodedCall 1 (bytesEncoding (Address.toBytes address)) utxosDecoder,
      rewardBalance = \address -> decodedCall 2 (bytesEncoding (Reward.toBytes address)) (decode D.decodeWord64),
      utxosWithAsset = \address asset -> decodedCall 3 (array [bytesEncoding (Address.toBytes address), assetEncoding asset]) utxosDecoder,
      utxoWithAsset = \asset -> decodedCall 4 (assetEncoding asset) (optionalDecoder Utxo.decodeCbor),
      resolveInputs = \inputs -> decodedCall 5 (list Input.encodeCbor inputs) utxosDecoder,
      resolveDatum = \hash -> decodedCall 6 (bytesEncoding (Datum.hashBytes hash)) (optionalDecoder Data.decodeCbor),
      awaitTransaction = \hash timeout -> decodedCall 7 (array [bytesEncoding (TxId.toBytes hash), C.encode (E.encodeWord64 timeout)]) (decode D.decodeBool),
      submitTransaction = \transaction -> decodedCall 8 (Tx.encodeCbor transaction) (decode D.decodeBytes >=> TxId.fromBytes),
      evaluateTransaction = \transaction utxos -> do
        reply <- call adapter 9 (array [Tx.encodeCbor transaction, list Utxo.encodeCbor utxos])
        pure (reply >>= Redeemer.decodeCollectionCbor >>= Eval.budgetsFromRedeemers Evaluation.TopLevel transaction)
    }
  where
    decodedCall operation request parser = do
      result <- call adapter operation request
      pure (result >>= parser)

-- | One complete typed handler action and encoding remains inside Runtime's user
-- worker. Errors preserve their exact constructors; there are no hidden defaults.
dispatch :: Provider -> Runtime.Dispatch
dispatch provider operation input = runExceptT $ case operation of
  0 -> do
    _ <- except (decode (C.array 0 (pure ())) input)
    value <- ExceptT (protocolParameters provider)
    except (Parameters.validateNative value)
    pure (Parameters.encodeSnapshot value)
  1 -> do
    address <- except (decode D.decodeBytes input >>= Address.fromBytes)
    list Utxo.encodeCbor <$> ExceptT (utxosAt provider address)
  2 -> do
    address <- except (decode D.decodeBytes input >>= Reward.fromBytes)
    C.encode . E.encodeWord64 <$> ExceptT (rewardBalance provider address)
  3 -> do
    (address, asset) <- except (decode (C.array 2 ((,) <$> addressDecoder <*> assetDecoder)) input)
    list Utxo.encodeCbor <$> ExceptT (utxosWithAsset provider address asset)
  4 -> do
    asset <- except (decode assetDecoder input)
    optional Utxo.encodeCbor <$> ExceptT (utxoWithAsset provider asset)
  5 -> do
    references <- except (decode (C.setList (C.nested input Input.decodeCbor)) input)
    list Utxo.encodeCbor <$> ExceptT (resolveInputs provider references)
  6 -> do
    hash <- except (decode D.decodeBytes input >>= Datum.hashFromBytes)
    optional Data.toCbor <$> ExceptT (resolveDatum provider hash)
  7 -> do
    (hash, timeout) <- except (decode (C.array 2 ((,) <$> hashDecoder <*> D.decodeWord64)) input)
    C.encode . E.encodeBool <$> ExceptT (awaitTransaction provider hash timeout)
  8 -> do
    transaction <- except (Tx.decodeCbor input)
    bytesEncoding . TxId.toBytes <$> ExceptT (submitTransaction provider transaction)
  9 -> do
    (transaction, utxos) <- except (decode (C.array 2 ((,) <$> C.nested input Tx.decodeCbor <*> C.list (C.nested input Utxo.decodeCbor))) input)
    budgets <- ExceptT (evaluateTransaction provider transaction utxos)
    values <- except (Eval.checkedRedeemers Evaluation.TopLevel transaction budgets)
    except (Redeemer.encodeCollectionCbor values)
  _ -> except (Left (UnsupportedOperation "provider.callback"))
  where
    addressDecoder = D.decodeBytes >>= either (fail . show) pure . Address.fromBytes
    assetDecoder = D.decodeBytes >>= either (fail . show) pure . assetFromBytes
    hashDecoder = D.decodeBytes >>= either (fail . show) pure . TxId.fromBytes

-- Internal wire helpers preserve each child's exact bytes.
decode :: (forall s. D.Decoder s a) -> ByteString -> Either Error a
decode = C.decodeAs InvalidCallbackResult

utxosDecoder :: ByteString -> Either Error [Utxo.Utxo]
utxosDecoder bytes = decode (C.list (C.nested bytes Utxo.decodeCbor)) bytes

optionalDecoder :: (ByteString -> Either Error a) -> ByteString -> Either Error (Maybe a)
optionalDecoder parser bytes = decode (C.optional (C.nested bytes parser)) bytes

bytesEncoding :: ByteString -> ByteString
bytesEncoding = C.encode . E.encodeBytes

assetEncoding :: AssetId -> ByteString
assetEncoding Ada = bytesEncoding B.empty
assetEncoding (Native policy assetName) = bytesEncoding (Policy.toBytes policy <> AssetName.toBytes assetName)

assetFromBytes :: ByteString -> Either Error AssetId
assetFromBytes bytes
  | B.null bytes = Right Ada
  | otherwise = Native <$> Policy.fromBytes (B.take 28 bytes) <*> AssetName.fromBytes (B.drop 28 bytes)

array :: [ByteString] -> ByteString
array values = C.encode (E.encodeListLen (fromIntegral (length values)) <> foldMap C.raw values)

list :: (a -> ByteString) -> [a] -> ByteString
list encoder = array . map encoder

optional :: (a -> ByteString) -> Maybe a -> ByteString
optional = maybe (C.encode E.encodeNull)
