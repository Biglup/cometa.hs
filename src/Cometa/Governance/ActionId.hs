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

-- | Identify a governance proposal by its containing transaction and index.
-- These are standalone protocol identities; construction does not establish
-- that a proposal exists or is currently eligible for voting.
--
-- @
-- import qualified Cometa.Governance.ActionId as ActionId
-- import qualified Cometa.TransactionId as TransactionId
--
-- firstProposal :: TransactionId.TransactionId -> ActionId.ActionId
-- firstProposal transaction = ActionId.ActionId transaction 0
-- @
module Cometa.Governance.ActionId
  ( ActionId (..),
    encodeCbor,
    decodeCbor,
    toText,
    fromText,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.Binary.Bech32 as Bech32
import Cometa.Error (Error (..))
import Cometa.Internal.Governance (ActionId (..))
import qualified Cometa.Internal.Governance as Internal
import qualified Cometa.TransactionId as TransactionId
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Text (Text)

-- DEFINITIONS ----------------------------------------------------------------

-- | Fresh definite CBOR @[transaction hash bytes, unsigned index]@ with the
-- shortest integer encoding. The index retains the full unsigned 64-bit range.
encodeCbor :: ActionId -> ByteString
encodeCbor = Internal.encodeActionId

-- | Decode exactly one complete action identifier. Both definite and indefinite
-- arrays and nonminimal integer encodings are accepted. Wrong arity, hash length,
-- non-unsigned index or trailing bytes returns
-- 'Cometa.Error.InvalidGovernanceCbor'. The result is semantic data; this
-- function does not retain the original encoding.
decodeCbor :: ByteString -> Either Error ActionId
decodeCbor = Internal.decodeActionId

-- | Encode the CIP-129 @gov_action@ Bech32 identifier: 32 transaction hash
-- bytes followed by the one-byte proposal index. Indices above 255 return
-- 'InvalidGovernanceActionTextIndex' without truncation. CBOR retains the full
-- unsigned 64-bit index range independently of this narrower display format.
toText :: ActionId -> Either Error Text
toText (ActionId transaction actionIndex)
  | actionIndex > 255 = Left (InvalidGovernanceActionTextIndex actionIndex)
  | otherwise = do
      prefix <- either (const (Left (NativeContractViolation "Invalid built-in governance action prefix"))) Right (Bech32.humanReadablePartFromText "gov_action")
      pure (Bech32.encodeLenient prefix (Bech32.dataPartFromBytes (TransactionId.toBytes transaction <> B.singleton (fromIntegral actionIndex))))

-- | Decode a checksummed CIP-129 @gov_action@ identifier with exactly 33
-- payload bytes. Uniform upper or lower case is accepted; mixed case, other
-- prefixes, incorrect padding, checksum or length returns
-- 'InvalidGovernanceActionText'. The decoded index is always 0 through 255.
fromText :: Text -> Either Error ActionId
fromText text = do
  (prefix, part) <- either (const failure) Right (Bech32.decodeLenient text)
  unlessValid (Bech32.humanReadablePartToText prefix == "gov_action")
  payload <- maybe failure Right (Bech32.dataPartToBytes part)
  unlessValid (B.length payload == 33)
  transaction <- TransactionId.fromBytes (B.take 32 payload)
  case B.uncons (B.drop 32 payload) of
    Just (actionIndex, _) -> Right (ActionId transaction (fromIntegral actionIndex))
    Nothing -> failure
  where
    failure :: Either Error a
    failure = Left (InvalidGovernanceActionText "Expected a CIP-129 gov_action identifier with a 33-byte payload")
    unlessValid True = Right ()
    unlessValid False = failure
