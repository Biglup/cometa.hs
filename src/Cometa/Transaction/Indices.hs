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

-- | Locate objects in the top-level transaction for deferred redeemers and
-- script arguments. Indices start at zero and can change when the body changes.
-- Missing objects return 'Nothing'. Subtransaction contents are independent.
--
-- @
-- import qualified Cometa.Transaction.Indices as Indices
--
-- spendingPosition reference transaction = Indices.findInput reference transaction
-- @
module Cometa.Transaction.Indices
  ( findInput,
    findReferenceInput,
    findOutput,
    findMintPolicy,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Term as T
import Cometa.Address (Address)
import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (Ada))
import qualified Cometa.Internal.TransactionCbor as Cbor
import Cometa.PolicyId (PolicyId)
import qualified Cometa.PolicyId as Policy
import Cometa.Transaction (Transaction)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Value as Value
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word64)

-- DEFINITIONS ----------------------------------------------------------------

-- | First spending-input position, ordered by transaction hash bytes and then
-- numeric output index. Duplicate references occupy separate positions.
findInput :: Input -> Transaction -> Maybe Word64
findInput reference = position (== reference) . sort . Fields.fieldInputs . fields

-- | First reference-input position in the same hash/index order as 'findInput'.
-- An absent reference-input field has no matching position.
findReferenceInput :: Input -> Transaction -> Maybe Word64
findReferenceInput reference = position (== reference) . sort . fromMaybe [] . Fields.fieldReferenceInputs . fields

-- | First output at the address containing at least the minimum lovelace.
-- Outputs retain their creation order. Other assets, datums and reference
-- scripts do not affect the match. The minimum spans the unsigned 64-bit range.
findOutput :: Address -> Word64 -> Transaction -> Maybe Word64
findOutput destination minimumLovelace = position matches . Fields.fieldOutputs . fields
  where
    matches output =
      Address.toBytes (Output.address output) == Address.toBytes destination
        && Value.quantity Ada (Output.value output) >= toInteger minimumLovelace

-- | Minting-policy position in ascending policy-hash byte order. Each policy
-- counts once, regardless of its asset names or whether it mints or burns.
-- Imported policies with only zero quantities or an empty asset map still count.
findMintPolicy :: PolicyId -> Transaction -> Maybe Word64
findMintPolicy policy transaction = do
  let bytes = Body.toCbor (Tx.body transaction)
  bodyFields <- either (const Nothing) Just (Cbor.decode (Cbor.mapFields bytes) bytes)
  mint <- Map.lookup 9 bodyFields
  policies <- either (const Nothing) Just (Cbor.decode (Cbor.entries (D.decodeBytes <* T.decodeTerm)) mint)
  position (== Policy.toBytes policy) (sort policies)

fields :: Transaction -> Fields.Fields
fields = Body.bodyFields . Body.toBody . Tx.body

position :: (a -> Bool) -> [a] -> Maybe Word64
position matches = go 0
  where
    go _ [] = Nothing
    go index (value : rest)
      | matches value = Just index
      | otherwise = go (index + 1) rest
