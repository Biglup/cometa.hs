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

-- | Constitutional committee cold authorities and their expiry epochs.
-- Use 'membersFromList' for runtime entries, then assemble @Committee members quorum@.
module Cometa.Governance.Committee
  ( Members,
    membersFromList,
    membersToList,
    emptyMembers,
    Committee (..),
    encodeCbor,
    decodeCbor,
    encodeMembers,
    decodeMembers,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Credential (CommitteeCold, Credential)
import Cometa.Error (Error (..))
import qualified Cometa.Internal.ProposalCbor as Cbor
import Cometa.UnitInterval (UnitInterval)
import qualified Cometa.UnitInterval as Interval
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Unique cold authorities, ordered by credential kind then exact hash bytes.
-- Expiry epochs retain the full unsigned 64-bit range; this is not era validation.
newtype Members = Members (Map (Credential CommitteeCold) Word64)
  deriving (Eq, Ord, Show)

-- | Membership and the exact validated fraction required for a successful vote.
data Committee = Committee
  { -- | Cold authorities and their expiry epochs.
    committeeMembers :: !Members,
    -- | Fraction of committee votes required for success, from zero through one.
    committeeQuorum :: !UnitInterval
  }
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate unique cold authorities. Duplicate keys return
-- 'DuplicateCommitteeMember', even when expiry epochs agree.
membersFromList :: [(Credential CommitteeCold, Word64)] -> Either Error Members
membersFromList values = Members <$> Cbor.uniqueMap DuplicateCommitteeMember values

-- | Entries in credential order, retaining expiry epochs exactly.
membersToList :: Members -> [(Credential CommitteeCold, Word64)]
membersToList (Members values) = Map.toAscList values

-- | No committee members.
emptyMembers :: Members
emptyMembers = Members Map.empty

-- | Fresh map encoding, sorted by credential kind and hash.
encodeMembers :: Members -> ByteString
encodeMembers members =
  Cbor.encode
    ( E.encodeMapLen (fromIntegral (length values))
        <> foldMap (\(key, epoch) -> Cbor.credentialEncoding key <> E.encodeWord64 epoch) values
    )
  where
    values = membersToList members

-- | Decode one complete members map, rejecting duplicate authorities.
decodeMembers :: ByteString -> Either Error Members
decodeMembers = Cbor.decode $ do
  pairs <- Cbor.entries ((,) <$> Cbor.credentialDecoder <*> D.decodeWord64)
  either (fail . show) pure (membersFromList pairs)

-- | Fresh definite array containing members and quorum.
encodeCbor :: Committee -> ByteString
encodeCbor (Committee members quorum) =
  Cbor.encode
    (E.encodeListLen 2 <> Cbor.raw (encodeMembers members) <> Cbor.raw (Interval.encodeCbor quorum))

-- | Decode one complete committee; malformed values, duplicate members and
-- trailing bytes return 'Cometa.Error.InvalidProposalCbor'.
decodeCbor :: ByteString -> Either Error Committee
decodeCbor =
  Cbor.decode
    ( Cbor.array
        2
        ( Committee
            <$> Cbor.nested decodeMembers
            <*> Cbor.nested Interval.decodeCbor
        )
    )
