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

-- | Validated 28-byte native-asset policy identifiers.
-- Import assigns an identifier; it does not execute or hash a policy script.
--
-- @
-- import qualified Cometa.Credential as Credential
-- import qualified Cometa.PolicyId as PolicyId
--
-- policy :: Credential.ScriptHash -> PolicyId.PolicyId
-- policy = PolicyId.fromScriptHash
-- @
module Cometa.PolicyId
  ( PolicyId,
    fromBytes,
    toBytes,
    fromHex,
    toHex,
    fromScriptHash,
    toScriptHash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | A 28-byte script-policy hash. Equality and ordering compare bytes
-- lexicographically. 'Show' is diagnostic output.
newtype PolicyId = PolicyId Credential.ScriptHash deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import exactly 28 bytes. Other lengths return 'InvalidPolicyIdLength'
-- with the actual byte count. This does not compute a script hash.
fromBytes :: ByteString -> Either Error PolicyId
fromBytes bytes
  | ByteString.length bytes /= 28 = Left (InvalidPolicyIdLength (ByteString.length bytes))
  | otherwise = PolicyId <$> Credential.scriptHashFromBytes bytes

-- | Exact policy-hash bytes.
toBytes :: PolicyId -> ByteString
toBytes = Credential.scriptHashBytes . toScriptHash

-- | Import exactly 56 ASCII hexadecimal digits, accepting either case.
-- Malformed hexadecimal returns 'InvalidHex'; valid hex of another byte length
-- returns 'InvalidPolicyIdLength', including empty input.
fromHex :: Text -> Either Error PolicyId
fromHex text = maybe (Left InvalidHex) fromBytes (Hex.decodeHex text)

-- | Lowercase hexadecimal without a prefix, always 56 digits.
toHex :: PolicyId -> Text
toHex = Hex.encodeHex . toBytes

-- | Assign an already validated script hash as a minting-policy identifier.
fromScriptHash :: Credential.ScriptHash -> PolicyId
fromScriptHash = PolicyId

-- | The script hash identifying this policy.
toScriptHash :: PolicyId -> Credential.ScriptHash
toScriptHash (PolicyId scriptHash) = scriptHash
