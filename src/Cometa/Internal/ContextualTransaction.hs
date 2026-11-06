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

-- | Owned native contextual utilities with complete buffer cleanup.
module Cometa.Internal.ContextualTransaction (findCertificate, requiredKeyHashes, runRequiredKeys) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.FFI.ContextualTransaction as FFI
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Utxo as Utxo
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek)

-- DEFINITIONS ----------------------------------------------------------------

findCertificate :: Certificate.EncodedCertificate -> Maybe ByteString -> IO (Either Error (Maybe Word64))
findCertificate _ Nothing = pure (Right Nothing)
findCertificate certificate (Just collection) =
  Runtime.withBytes collection $ \bytes size ->
    Runtime.withBytes (Certificate.toCbor certificate) $ \target targetSize ->
      alloca $ \index -> do
        status <- FFI.cCertificateIndex bytes size target targetSize index
        if toInteger status == Code.toNumber Code.ElementNotFound
          then pure (Right Nothing)
          else do
            checked <- Runtime.checkStatus "transaction.indices.certificate" status
            case checked of
              Left failure -> pure (Left failure)
              Right () -> Right . Just <$> peek index

requiredKeyHashes :: Tx.Transaction -> [Utxo.Utxo] -> IO (Either Error (Set Blake2b.Blake2bHash))
requiredKeyHashes transaction resolved = case validateResolution transaction resolved of
  Left failure -> pure (Left failure)
  Right () -> do
    result <- runRequiredKeys (Tx.encodeCbor transaction) (encodeUtxos resolved)
    pure $ do
      bytes <- result
      hashes <- Cbor.decode (Cbor.setList D.decodeBytes) bytes
      unless (all ((== 28) . B.length) hashes) (Left (NativeContractViolation "transaction.authority.hashSize"))
      Set.fromList <$> traverse Blake2b.fromBytes hashes

validateResolution :: Tx.Transaction -> [Utxo.Utxo] -> Either Error ()
validateResolution transaction resolved = do
  unless (Set.size available == length references) (Left (InvalidTransactionField "Duplicate resolved UTxO references"))
  unless (all (`Set.member` available) required) (Left (InvalidTransactionField "All spending and collateral inputs must resolve"))
  where
    body = Body.toBody (Tx.body transaction)
    required = Fields.fieldInputs (Body.bodyFields body) ++ fromMaybe [] (Body.bodyCollateral body)
    references = map Utxo.input resolved
    available = Set.fromList references

encodeUtxos :: [Utxo.Utxo] -> ByteString
encodeUtxos values = Cbor.encode (E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Utxo.encodeCbor) values)

-- | Internal malformed-transport boundary for deterministic cleanup tests.
runRequiredKeys :: ByteString -> ByteString -> IO (Either Error ByteString)
runRequiredKeys transaction resolved =
  Runtime.withBytes transaction $ \bytes size ->
    Runtime.withBytes resolved $ \utxos utxosSize ->
      Runtime.withOwnedBuffer "transaction.authority.requiredKeyHashes" (FFI.cRequiredKeys bytes size utxos utxosSize)
