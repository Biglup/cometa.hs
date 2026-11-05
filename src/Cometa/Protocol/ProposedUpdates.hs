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

-- | Legacy genesis-authorized protocol update proposals. These envelopes are
-- distinct from Conway parameter-change governance actions. Validate input hashes
-- once, then collect changes with 'fromList' and assemble @UpdateProposal epoch changes@.
module Cometa.Protocol.ProposedUpdates
  ( ProposedUpdates,
    empty,
    fromList,
    toList,
    UpdateProposal (..),
    EncodedUpdates,
    encodeCbor,
    decodeCbor,
    toUpdates,
    toCbor,
    EncodedProposal,
    encodeProposal,
    decodeProposal,
    toProposal,
    proposalCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Credential (Genesis, KeyHash)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.ProposalCbor as Cbor
import Cometa.Protocol.Parameters.Update (Update)
import qualified Cometa.Protocol.Parameters.Update as Update
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Unique 28-byte genesis key hashes and their sparse parameter changes.
-- Equality is semantic; fresh encoding sorts by hash bytes.
newtype ProposedUpdates = ProposedUpdates (Map (KeyHash Genesis) Update) deriving (Eq, Show)

-- | Proposed changes and their activation epoch (unsigned 64-bit).
-- Assembly does not establish era eligibility or authorization.
data UpdateProposal = UpdateProposal
  { -- | Epoch in which the proposal takes effect if accepted.
    updateProposalEpoch :: !Word64,
    -- | Genesis-authorized sparse protocol parameter changes.
    updateProposalChanges :: !ProposedUpdates
  }
  deriving (Eq, Show)

-- | Exact map bytes with semantic changes. Equality and ordering compare bytes.
data EncodedUpdates = EncodedUpdates !ByteString !ProposedUpdates deriving (Show)

instance Eq EncodedUpdates where
  left == right = toCbor left == toCbor right

instance Ord EncodedUpdates where
  compare left right = compare (toCbor left) (toCbor right)

-- | Exact proposal bytes with semantic epoch and changes. Equality and ordering
-- compare encoded bytes, not semantic data.
data EncodedProposal = EncodedProposal !ByteString !UpdateProposal deriving (Show)

instance Eq EncodedProposal where
  left == right = proposalCbor left == proposalCbor right

instance Ord EncodedProposal where
  compare left right = compare (proposalCbor left) (proposalCbor right)

-- DEFINITIONS ----------------------------------------------------------------

-- | No proposed changes.
empty :: ProposedUpdates
empty = ProposedUpdates Map.empty

-- | Validate unique genesis hashes. Repeated keys return 'DuplicateProtocolUpdate'
-- even when their updates agree, rather than silently discarding an instruction.
fromList :: [(KeyHash Genesis, Update)] -> Either Error ProposedUpdates
fromList values = ProposedUpdates <$> Cbor.uniqueMap DuplicateProtocolUpdate values

-- | Entries sorted by exact genesis hash bytes.
toList :: ProposedUpdates -> [(KeyHash Genesis, Update)]
toList (ProposedUpdates values) = Map.toAscList values

-- | Fresh definite map, with sorted hashes and fresh sparse update encodings.
encodeCbor :: ProposedUpdates -> ByteString
encodeCbor value =
  Cbor.encode
    ( E.encodeMapLen (fromIntegral (length entries))
        <> foldMap (\(key, change) -> E.encodeBytes (Credential.keyHashBytes key) <> Cbor.raw (Update.encodeCbor change)) entries
    )
  where
    entries = toList value

-- | Decode one complete map and retain original bytes. Duplicate hashes,
-- incorrect hash lengths, invalid updates and trailing bytes return
-- 'Cometa.Error.InvalidProposalCbor'.
decodeCbor :: ByteString -> Either Error EncodedUpdates
decodeCbor bytes = EncodedUpdates bytes <$> Cbor.decode updatesDecoder bytes

-- | Inspect semantic changes without altering the exact encoding.
toUpdates :: EncodedUpdates -> ProposedUpdates
toUpdates (EncodedUpdates _ value) = value

-- | Exact imported update-map CBOR.
toCbor :: EncodedUpdates -> ByteString
toCbor (EncodedUpdates bytes _) = bytes

-- | Fresh definite @[changes, epoch]@ array with shortest integers.
encodeProposal :: UpdateProposal -> ByteString
encodeProposal (UpdateProposal epoch changes) =
  Cbor.encode
    (E.encodeListLen 2 <> Cbor.raw (encodeCbor changes) <> E.encodeWord64 epoch)

-- | Decode a complete legacy proposal and retain exact bytes. Invalid schema
-- or trailing bytes returns 'Cometa.Error.InvalidProposalCbor'.
decodeProposal :: ByteString -> Either Error EncodedProposal
decodeProposal bytes =
  EncodedProposal bytes
    <$> Cbor.decode
      (Cbor.array 2 (flip UpdateProposal <$> updatesDecoder <*> D.decodeWord64))
      bytes

-- | Inspect activation epoch and changes without altering retained bytes.
toProposal :: EncodedProposal -> UpdateProposal
toProposal (EncodedProposal _ value) = value

-- | Exact imported legacy proposal CBOR.
proposalCbor :: EncodedProposal -> ByteString
proposalCbor (EncodedProposal bytes _) = bytes

updatesDecoder :: D.Decoder s ProposedUpdates
updatesDecoder = do
  entries <- Cbor.entries $ do
    key <- D.decodeBytes >>= either (fail . show) pure . Credential.keyHashFromBytes
    change <- Update.toUpdate <$> Cbor.nested Update.decodeCbor
    pure (key, change)
  either (fail . show) pure (fromList entries)
