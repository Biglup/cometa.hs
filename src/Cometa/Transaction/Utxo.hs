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

-- | An unspent-output snapshot pairs a reference with its resolved output.
-- Construction does not query chain state or prove that the output is unspent.
--
-- @
-- resolved reference output = utxo reference output
-- @
module Cometa.Transaction.Utxo (Utxo, utxo, input, output, encodeCbor, decodeCbor) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import Cometa.Error (Error)
import qualified Cometa.Internal.TransactionCbor as Cbor
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Input as Input
import Cometa.Transaction.Output (Output)
import qualified Cometa.Transaction.Output as Output
import Data.ByteString (ByteString)

-- TYPES ----------------------------------------------------------------------

-- | Owned resolved reference and semantic output. Equality compares both fields.
data Utxo = Utxo !Input !Output deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble a resolved reference and its output without chain-state validation.
utxo :: Input -> Output -> Utxo
utxo = Utxo

-- | Reference identifying the resolved output.
input :: Utxo -> Input
input (Utxo result _) = result

-- | Resolved semantic output; inspecting it has no chain or native effects.
output :: Utxo -> Output
output (Utxo _ result) = result

-- | Fresh native UTxO pair @[input, output]@. This is a snapshot interchange
-- encoding, not an on-chain transaction-body field.
encodeCbor :: Utxo -> ByteString
encodeCbor (Utxo reference resolved) = Cbor.encode (E.encodeListLen 2 <> Cbor.raw (Input.encodeCbor reference) <> Cbor.raw (Output.encodeCbor resolved))

-- | Decode a complete definite or indefinite pair through the public input and
-- output schemas. Malformed data and trailing bytes return structured errors.
-- This snapshot API inspects semantic outputs; use an enclosing exact transaction
-- or 'Output.EncodedOutput' when preserving signed-body identity is required.
decodeCbor :: ByteString -> Either Error Utxo
decodeCbor bytes = Cbor.decode (Cbor.array 2 (Utxo <$> Cbor.nested bytes Input.decodeCbor <*> (Output.toOutput <$> Cbor.nested bytes Output.decodeCbor))) bytes
