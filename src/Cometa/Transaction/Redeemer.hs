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

-- | Indexed script arguments and execution budgets. Purpose and zero-based
-- index identify a redeemer; the index refers to the corresponding body field.
-- @Redeemer Spending 0 (PlutusData.fromData (PlutusData.Integer 42)) (ExUnits 10 20)@
-- assembles an argument and budget without running the script.
module Cometa.Transaction.Redeemer
  ( Purpose (..),
    Redeemer (..),
    encodeCbor,
    decodeCbor,
    encodeCollectionCbor,
    decodeCollectionCbor,
    mkCollection,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as C
import qualified Cometa.PlutusData as PlutusData
import Cometa.Protocol.ExUnits (ExUnits)
import qualified Cometa.Protocol.ExUnits as ExUnits
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.List as List
import Data.Word (Word32)

-- TYPES ----------------------------------------------------------------------

-- | Ledger purpose tags zero through six. Guarding requires an era supporting
-- transaction guards; this standalone codec does not establish era acceptance.
data Purpose = Spending | Minting | Certifying | Rewarding | Voting | Proposing | Guarding
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Purpose, zero-based body-field index, exact script argument, and memory/CPU budget.
data Redeemer = Redeemer
  { -- | Body operation authorized by the script.
    purpose :: !Purpose,
    -- | Zero-based position in the corresponding body collection, at most 2^32-1.
    index :: !Word32,
    -- | Exact script argument encoding, preserved during witness edits.
    argument :: !PlutusData.EncodedPlutusData,
    -- | Memory units and CPU steps supplied by script evaluation.
    executionUnits :: !ExUnits
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate unique purpose/index pairs and sort by purpose then index.
-- Duplicate identifiers are rejected even when their arguments agree.
mkCollection :: [Redeemer] -> Either Error [Redeemer]
mkCollection values =
  let sorted = List.sortOn identifier values
   in if any (\(a, b) -> identifier a == identifier b) (zip sorted (drop 1 sorted))
        then Left (InvalidRedeemerCbor "Duplicate redeemer purpose/index")
        else Right sorted

identifier :: Redeemer -> (Purpose, Word32)
identifier value = (purpose value, index value)

-- | Encode the historical four-element standalone redeemer form.
encodeCbor :: Redeemer -> ByteString
encodeCbor value = C.encode (E.encodeListLen 4 <> keyEncoding value <> valueEncoding value)

-- | Decode one standalone four-element form, retaining exact argument CBOR.
decodeCbor :: ByteString -> Either Error Redeemer
decodeCbor input = C.decodeAs InvalidRedeemerCbor (C.array 4 (decoder input)) input

-- | Encode a Conway-style map, sorted by purpose/index. Duplicate identifiers
-- fail explicitly; no map conversion silently overwrites an argument.
encodeCollectionCbor :: [Redeemer] -> Either Error ByteString
encodeCollectionCbor values = do
  sorted <- mkCollection values
  pure (C.encode (E.encodeMapLen (fromIntegral (length sorted)) <> foldMap entry sorted))
  where
    entry value = E.encodeListLen 2 <> keyEncoding value <> E.encodeListLen 2 <> valueEncoding value

-- | Accept the historical array or Conway map form. Imported collection order
-- normalizes by purpose/index; duplicate identifiers and indices above 2^32-1 fail.
decodeCollectionCbor :: ByteString -> Either Error [Redeemer]
decodeCollectionCbor input = C.decodeAs InvalidRedeemerCbor parser input >>= mkCollection
  where
    parser = do
      token <- D.peekTokenType
      if token == D.TypeMapLen || token == D.TypeMapLenIndef
        then C.entries $ do
          (tag, ix) <- C.array 2 ((,) <$> purposeDecoder <*> D.decodeWord32)
          C.array 2 (Redeemer tag ix <$> C.nested input PlutusData.decodeCbor <*> C.nested input ExUnits.decodeCbor)
        else C.list (C.array 4 (decoder input))

decoder :: ByteString -> D.Decoder s Redeemer
decoder input = Redeemer <$> purposeDecoder <*> D.decodeWord32 <*> C.nested input PlutusData.decodeCbor <*> C.nested input ExUnits.decodeCbor

purposeDecoder :: D.Decoder s Purpose
purposeDecoder = do
  tag <- D.decodeWord
  unless (tag <= 6) (fail "Unknown redeemer purpose")
  pure (toEnum (fromIntegral tag))

keyEncoding :: Redeemer -> E.Encoding
keyEncoding value = E.encodeWord (fromIntegral (fromEnum (purpose value))) <> E.encodeWord32 (index value)

valueEncoding :: Redeemer -> E.Encoding
valueEncoding value = C.raw (PlutusData.toCbor (argument value)) <> C.raw (ExUnits.encodeCbor (executionUnits value))
