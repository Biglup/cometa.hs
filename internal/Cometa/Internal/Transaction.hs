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

-- | Encoding-preservation prototype, not a public transaction model. Every value
-- is a Haskell-owned immutable snapshot; no native handle survives an operation.
-- Unchanged values retain exact input bytes, including historical/block frames.
module Cometa.Internal.Transaction
  ( Transaction,
    decodeCbor,
    encodeCbor,
    bodyCbor,
    bodyHash,
    witnessCbor,
    fee,
    setFee,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.FFI.Transaction as FFI
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (withOwnedOutput)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CSize, CUInt)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | Original full encoding, body encoding/hash, fee and witness encoding.
-- Constructors stay private so callers cannot desynchronize these snapshots.
data Transaction = Transaction !ByteString !ByteString !ByteString !Word64 !ByteString
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate exactly one native transaction and copy its fee and identity bytes.
-- Native decoding supports historical 3-element, legacy/mempool 4-element and
-- Dijkstra block 4-element frames, including indefinite outer arrays. Accepted
-- body/witness contents follow the pinned native decoder, not a generic CBOR AST.
-- Malformed, incomplete and trailing input returns a native failure.
decodeCbor :: ByteString -> IO (Either NativeFailure Transaction)
decodeCbor bytes = withInput bytes $ \pointer size ->
  withOwnedOutput "transaction.decodeCbor" FFI.cFree (FFI.cDecode pointer size) (copySnapshot "transaction.decodeCbor")

-- | Exact original full input bytes, or the fresh encoding produced by an edit.
encodeCbor :: Transaction -> ByteString
encodeCbor (Transaction bytes _ _ _ _) = bytes

-- | Exact bytes hashed for the transaction ID, independent of the outer frame.
bodyCbor :: Transaction -> ByteString
bodyCbor (Transaction _ bytes _ _ _) = bytes

-- | BLAKE2b-256 of 'bodyCbor', copied from the native transaction ID.
bodyHash :: Transaction -> ByteString
bodyHash (Transaction _ _ digest _ _) = digest

-- | Exact encoded witness map retained from decoding or produced by an edit.
witnessCbor :: Transaction -> ByteString
witnessCbor (Transaction _ _ _ _ bytes) = bytes

-- | Fee in lovelace; no integer conversion or truncation is performed.
fee :: Transaction -> Word64
fee (Transaction _ _ _ lovelace _) = lovelace

-- | Change the fee on an independent native deep clone. A same-fee update is an
-- exact no-op, preserving the full encoding and signatures. A changed fee drops
-- outer vkey and bootstrap signatures and recomputes body encoding/hash. Scripts,
-- datums, redeemers and auxiliary data remain; this is not transaction balancing
-- or a guarantee that the edited transaction is valid for submission.
--
-- The native serializer preserves historical/block frame ordering but emits a
-- definite outer array. Body re-encoding may normalize noncanonical encodings.
-- The source snapshot remains unchanged on success, failure or cancellation.
setFee :: Word64 -> Transaction -> IO (Either NativeFailure Transaction)
setFee lovelace transaction
  | lovelace == fee transaction = pure (Right transaction)
  | otherwise = withInput (encodeCbor transaction) $ \pointer size ->
      withOwnedOutput "transaction.setFee" FFI.cFree (FFI.cSetFee pointer size lovelace) (copySnapshot "transaction.setFee")

-- | Keep input bytes alive through the complete safe native acquisition.
withInput :: ByteString -> (Ptr Word8 -> CSize -> IO value) -> IO value
withInput bytes action = ByteString.useAsCStringLen bytes $ \(pointer, size) ->
  action (castPtr pointer) (fromIntegral size)

-- | Snapshot the four borrowed spans before the native owner is released.
copySnapshot :: Text -> Ptr FFI.NativeSnapshot -> IO (Either NativeFailure Transaction)
copySnapshot operation pointer = do
  full <- copyPart operation pointer 0
  body <- copyPart operation pointer 1
  digest <- copyPart operation pointer 2
  witnesses <- copyPart operation pointer 3
  lovelace <- FFI.cFee pointer
  pure $ do
    fullBytes <- full
    bodyBytes <- body
    hashBytes <- digest
    witnessBytes <- witnesses
    if ByteString.length hashBytes /= 32
      then Left (NativeContractFailure operation)
      else Right (Transaction fullBytes bodyBytes hashBytes lovelace witnessBytes)

-- | Copy a nonempty bounded span; neither pointer nor native-size conversion
-- escapes the ownership scope. Field numbers belong only to the private adapter.
copyPart :: Text -> Ptr FFI.NativeSnapshot -> CUInt -> IO (Either NativeFailure ByteString)
copyPart operation pointer field = alloca $ \sizeSlot -> do
  poke sizeSlot 0
  bytes <- FFI.cBytes pointer field sizeSlot
  size <- peek sizeSlot
  if bytes == nullPtr || size == 0 || toInteger size > toInteger (maxBound :: Int)
    then pure (Left (NativeContractFailure operation))
    else Right <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)
