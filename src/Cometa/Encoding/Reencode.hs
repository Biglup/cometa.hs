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

-- | Explicit native representation changes for advanced encoding workflows.
-- These operations produce distinct snapshots; their source values remain exact.
-- They follow native representation policy, including retained indefinite script
-- lists and mixed-depth transaction rules. They are not canonical-CBOR codecs.
--
-- Re-encoding can change script hashes, transaction IDs, auxiliary-data hashes
-- and script-data commitments. Transaction signatures are retained verbatim and
-- may become invalid. No commitment, signature or ledger rule is repaired.
-- Inspect the result and assemble/sign a new transaction when identity changes.
-- Ordinary transaction setters remain the interface for normal body edits.
--
-- @
-- import qualified Cometa.Encoding.Reencode as Reencode
-- import qualified Cometa.Script.Native as Native
--
-- reencodedCondition = Reencode.nativeScript (Native.invalidBefore 100)
-- @
module Cometa.Encoding.Reencode
  ( nativeScript,
    nativeScripts,
    transaction,
    subTransaction,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Encoding.Cbor as Cbor
import Cometa.Error (Error)
import qualified Cometa.Internal.Reencode as Internal
import qualified Cometa.Script.Native as Native
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.Transaction as Tx

-- DEFINITIONS ----------------------------------------------------------------

-- | Re-encode native condition nodes with fresh definite node arrays and
-- shortest scalar encodings, recursively retaining each child list's existing
-- definite/indefinite shape, order and duplicates. The resulting script hash may
-- differ. Native parsing/encoding failures are explicit; the source is unchanged.
nativeScript :: Native.NativeScript -> IO (Either Error Native.NativeScript)
nativeScript source = fmap (>>= Native.decodeCbor) (Internal.reencode "encoding.reencode.nativeScript" 0 (Native.encodeCbor source))

-- | Validate and re-encode an encoded native-script list. Retain the outer
-- list's definite/indefinite shape and recursively apply 'nativeScript' policy
-- to its children. Definite lengths use their shortest encoding. Empty lists,
-- order and duplicates are retained. A non-list or invalid script returns a
-- native error. Source bytes remain unchanged.
nativeScripts :: Cbor.Cbor -> IO (Either Error Cbor.Cbor)
nativeScripts source = do
  result <- Internal.reencode "encoding.reencode.nativeScripts" 1 (Cbor.toBytes source)
  either (pure . Left) Cbor.fromBytes result

-- | Re-encode an outer transaction body, witness collections and auxiliary
-- container under native policy. Nested intent bodies remain exact. Witness
-- datum/redeemer data are re-encoded recursively; native-script child encodings
-- in witnesses are retained and witness set tags are freshly emitted.
-- Existing signatures and commitments are retained, so they may become invalid.
-- Native decoding failures include unsupported source representations, such as
-- indefinite body maps. The original transaction is unchanged.
transaction :: Tx.Transaction -> IO (Either Error Tx.Transaction)
transaction source = fmap (>>= Tx.decodeCbor) (Internal.reencode "encoding.reencode.transaction" 2 (Tx.encodeCbor source))

-- | Re-encode one intent's body, witness collections and auxiliary container
-- with the same policy and signature/commitment caveats as 'transaction'. Its
-- body ID may change. This operation does not alter an enclosing transaction or
-- the original intent; native parsing/encoding failures remain explicit.
subTransaction :: Sub.SubTransaction -> IO (Either Error Sub.SubTransaction)
subTransaction source = fmap (>>= Sub.decodeCbor) (Internal.reencode "encoding.reencode.subTransaction" 3 (Sub.encodeCbor source))
