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

-- | A constitution's off-chain anchor and optional guardrails script hash.
-- Assembly is total: @Constitution anchor Nothing@ has no guardrails script.
module Cometa.Governance.Constitution
  ( Constitution (..),
    encodeCbor,
    decodeCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Credential (ScriptHash)
import qualified Cometa.Credential as C
import Cometa.Error (Error)
import Cometa.Governance.Anchor (Anchor)
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Internal.ProposalCbor as Cbor
import Data.ByteString (ByteString)

-- TYPES ----------------------------------------------------------------------

-- | Immutable metadata and an optional exact 28-byte guardrails hash.
data Constitution = Constitution
  { -- | Off-chain constitution location and expected payload hash.
    constitutionAnchor :: !Anchor,
    -- | Optional guardrails script hash; absence encodes as null.
    constitutionScript :: !(Maybe ScriptHash)
  }
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite CBOR; absence of a guardrails script encodes as null.
encodeCbor :: Constitution -> ByteString
encodeCbor (Constitution anchor script) =
  Cbor.encode
    ( E.encodeListLen 2
        <> Cbor.raw (Anchor.encodeCbor anchor)
        <> Cbor.maybeEncoding (E.encodeBytes . C.scriptHashBytes) script
    )

-- | Decode one complete constitution; invalid schema or trailing bytes returns
-- 'Cometa.Error.InvalidProposalCbor'. This returns semantic data.
decodeCbor :: ByteString -> Either Error Constitution
decodeCbor =
  Cbor.decode
    ( Cbor.array
        2
        ( Constitution
            <$> Cbor.nested Anchor.decodeCbor
            <*> Cbor.optional (D.decodeBytes >>= either (fail . show) pure . C.scriptHashFromBytes)
        )
    )
