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

-- | Checked domain requests and operation-scoped native utility marshaling.
-- Each request decodes fresh independent owners in C. Runtime.withOwnedBuffer
-- releases even partial output on failure and copies before releasing success.
module Cometa.Internal.Building
  ( ImplicitCoin (..),
    minimumAda,
    baseFee,
    minimumFee,
    referenceScriptFee,
    scriptDataHash,
    implicitCoin,
    subTransactionImplicitCoin,
    runUnchecked,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.Building as FFI
import qualified Cometa.Internal.FFI.CoinSelection as Selection
import qualified Cometa.Internal.ParameterSnapshot as Snapshot
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Internal.TransactionFields as Fields
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import Cometa.Transaction.Datum (Hash32)
import qualified Cometa.Transaction.Datum as Datum
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text
import Data.Word (Word64)
import Foreign.C.Types (CUInt)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (castPtr)
import Foreign.Storable (peek)

-- TYPES ----------------------------------------------------------------------

-- | Top-level reward withdrawals, deposits charged and deposits reclaimed,
-- all in lovelace. The three totals are separate unsigned 64-bit quantities.
data ImplicitCoin = ImplicitCoin
  { -- | Reward withdrawals included in this body.
    withdrawals :: !Word64,
    -- | Certificate and governance proposal deposits paid.
    deposits :: !Word64,
    -- | Stake credential and DRep deposits returned by certificates.
    reclaimedDeposits :: !Word64
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

minimumAda :: Word64 -> Output.Output -> IO (Either Error Word64)
minimumAda cost output = Runtime.withBytes (Output.encodeCbor output) $ \bytes size -> alloca $ \result -> do
  code <- Selection.cMinimumAda bytes size cost result
  status <- Runtime.checkStatus "building.minimumAda" code
  case status of
    Left failure -> pure (Left failure)
    Right () -> Right <$> peek result

baseFee :: Word64 -> Word64 -> Tx.Transaction -> IO (Either Error Word64)
baseFee constant coefficient transaction = compute 4 D.decodeWord64 [Cbor.raw (Tx.encodeCbor transaction), E.encodeWord64 constant, E.encodeWord64 coefficient]

minimumFee :: Parameters.Parameters -> [Utxo.Utxo] -> Tx.Transaction -> IO (Either Error Word64)
minimumFee parameters resolved transaction = case validate of
  Left failure -> pure (Left failure)
  Right () -> compute 0 D.decodeWord64 [Cbor.raw (Tx.encodeCbor transaction), Cbor.raw (Snapshot.encodeSnapshot parameters), encodeUtxos (pricedInputs transaction resolved)]
  where
    validate = do
      validateParameters parameters
      validateReferences resolved
      unless (Set.fromList (map Utxo.input resolved) == Set.unions (pricedInputSets transaction)) (Left (InvalidBuildingRequest "Resolved inputs must exactly cover top-level and subtransaction spending and reference inputs"))
      require (Parameters.parameterExecutionCosts parameters) "Execution prices are required"
      require (Parameters.parameterRefScriptCostPerByte parameters) "Reference script byte price is required"

referenceScriptFee :: Parameters.Parameters -> [Utxo.Utxo] -> IO (Either Error Word64)
referenceScriptFee parameters resolved = case validate of
  Left failure -> pure (Left failure)
  Right () -> compute 1 D.decodeWord64 [Cbor.raw (Snapshot.encodeSnapshot parameters), encodeUtxos resolved]
  where
    validate = do
      validateParameters parameters
      validateReferences resolved
      require (Parameters.parameterRefScriptCostPerByte parameters) "Reference script byte price is required"

scriptDataHash :: Models.CostModels -> Witnesses.EncodedWitnesses -> IO (Either Error (Maybe Hash32))
scriptDataHash models witnesses = do
  result <- compute 3 (Cbor.optional D.decodeBytes) [Cbor.raw (Models.encodeCbor models), Cbor.raw (Witnesses.toCbor witnesses)]
  pure (result >>= traverse Datum.hashFromBytes)

implicitCoin :: Parameters.Parameters -> Tx.Transaction -> IO (Either Error ImplicitCoin)
implicitCoin parameters transaction = case validateParameters parameters of
  Left failure -> pure (Left failure)
  Right () -> compute 2 (Cbor.array 3 (ImplicitCoin <$> D.decodeWord64 <*> D.decodeWord64 <*> D.decodeWord64)) [Cbor.raw (Tx.encodeCbor transaction), Cbor.raw (Snapshot.encodeSnapshot parameters)]

subTransactionImplicitCoin :: Parameters.Parameters -> Sub.SubTransaction -> IO (Either Error ImplicitCoin)
subTransactionImplicitCoin parameters transaction = case validateParameters parameters of
  Left failure -> pure (Left failure)
  Right () -> compute 5 (Cbor.array 3 (ImplicitCoin <$> D.decodeWord64 <*> D.decodeWord64 <*> D.decodeWord64)) [Cbor.raw (Sub.encodeCbor transaction), Cbor.raw (Snapshot.encodeSnapshot parameters)]

validateParameters :: Parameters.Parameters -> Either Error ()
validateParameters = Snapshot.validateNative

require :: Maybe a -> Data.Text.Text -> Either Error ()
require value message = case value of
  Nothing -> Left (InvalidBuildingRequest message)
  Just _ -> Right ()

validateReferences :: [Utxo.Utxo] -> Either Error ()
validateReferences resolved = unless (Set.size (Set.fromList (map Utxo.input resolved)) == length resolved) (Left (InvalidBuildingRequest "Duplicate resolved reference input"))

-- Each body's spending/reference union is priced once; the native balancer
-- concatenates those per-body lists rather than deduplicating across a batch.
pricedInputSets :: Tx.Transaction -> [Set.Set Input]
pricedInputSets transaction = map inputs (Body.bodyFields body : subFields)
  where
    body = Body.toBody (Tx.body transaction)
    subFields = maybe [] (map (SubBody.fields . SubBody.toBody . Sub.body)) (Body.bodySubTransactions body)
    inputs fields = Set.fromList (Fields.fieldInputs fields <> fromMaybe [] (Fields.fieldReferenceInputs fields))

pricedInputs :: Tx.Transaction -> [Utxo.Utxo] -> [Utxo.Utxo]
pricedInputs transaction resolved = concatMap (\refs -> filter (\utxo -> Set.member (Utxo.input utxo) refs) resolved) (pricedInputSets transaction)

encodeUtxos :: [Utxo.Utxo] -> E.Encoding
encodeUtxos values = E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Utxo.encodeCbor) values

compute :: CUInt -> (forall s. D.Decoder s a) -> [E.Encoding] -> IO (Either Error a)
compute operation decoder fields = do
  result <- runUnchecked operation (Cbor.encode (E.encodeListLen (fromIntegral (length fields)) <> mconcat fields))
  pure (result >>= Cbor.decodeAs InvalidBuildingRequest decoder)

-- | Private malformed-request hook. Fresh native owners are released before return.
runUnchecked :: CUInt -> ByteString -> IO (Either Error ByteString)
runUnchecked operation request = B.useAsCStringLen request $ \(bytes, size) -> Runtime.withOwnedBuffer "building.compute" (FFI.cCompute operation (castPtr bytes) (fromIntegral size))
