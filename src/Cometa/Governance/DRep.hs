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

-- | Delegation targets distinguish a DRep credential from the predefined
-- always-abstain and always-no-confidence targets. Special targets cannot be
-- used as voting authorities.
--
-- @
-- import qualified Cometa.Governance.DRep as DRep
--
-- abstainingTarget :: DRep.DRep
-- abstainingTarget = DRep.AlwaysAbstain
-- @
module Cometa.Governance.DRep
  ( DRep (..),
    encodeCbor,
    decodeCbor,
    toText,
    fromText,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.Binary.Bech32 as Bech32
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import Cometa.Internal.Governance (DRep (..))
import qualified Cometa.Internal.Governance as Internal
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Text (Text)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode fresh definite CBOR: @[0, key hash]@, @[1, script hash]@, @[2]@
-- (always abstain), or @[3]@ (always no confidence).
encodeCbor :: DRep -> ByteString
encodeCbor = Internal.encodeDRep

-- | Decode one complete DRep. Definite or indefinite arrays and nonminimal
-- unsigned codes are accepted. Codes, arity and 28-byte credential lengths are
-- checked; invalid input or trailing bytes returns
-- 'Cometa.Error.InvalidGovernanceCbor'. Original encoding is not retained.
decodeCbor :: ByteString -> Either Error DRep
decodeCbor = Internal.decodeDRep

-- | Encode a credential DRep as CIP-129 @drep@ Bech32 text, using header
-- @0x22@ for a key or @0x23@ for a script and its 28-byte hash. The special
-- abstain and no-confidence delegation targets have no credential identifier;
-- they return 'UnsupportedOperation'.
toText :: DRep -> Either Error Text
toText (DRepCredential credential) = do
  prefix <- either (const (Left (NativeContractViolation "Invalid built-in DRep prefix"))) Right (Bech32.humanReadablePartFromText "drep")
  let payload = case credential of
        Credential.KeyCredential hash -> B.cons 0x22 (Credential.keyHashBytes hash)
        Credential.ScriptCredential hash -> B.cons 0x23 (Credential.scriptHashBytes hash)
  pure (Bech32.encodeLenient prefix (Bech32.dataPartFromBytes payload))
toText AlwaysAbstain = Left (UnsupportedOperation "DRep.toText: always-abstain has no credential identifier")
toText AlwaysNoConfidence = Left (UnsupportedOperation "DRep.toText: always-no-confidence has no credential identifier")

-- | Import either CIP-105 (28-byte @drep@ key or @drep_script@ script) or
-- CIP-129 (29-byte @drep@ header and hash) text. Uniform upper or lower case is
-- accepted. Mixed case, invalid checksum/padding, other prefixes or headers and
-- wrong lengths return 'InvalidDRepText'. Re-encoding always produces CIP-129.
fromText :: Text -> Either Error DRep
fromText text = do
  (prefix, part) <- either (const failure) Right (Bech32.decodeLenient text)
  payload <- maybe failure Right (Bech32.dataPartToBytes part)
  case (Bech32.humanReadablePartToText prefix, B.length payload) of
    ("drep", 28) -> key payload
    ("drep_script", 28) -> script payload
    ("drep", 29) -> case B.uncons payload of
      Just (0x22, hash) -> key hash
      Just (0x23, hash) -> script hash
      _ -> failure
    _ -> failure
  where
    failure :: Either Error a
    failure = Left (InvalidDRepText "Expected a CIP-105 or CIP-129 DRep credential identifier")
    key payload = DRepCredential . Credential.KeyCredential <$> Credential.keyHashFromBytes payload
    script payload = DRepCredential . Credential.ScriptCredential <$> Credential.scriptHashFromBytes payload
