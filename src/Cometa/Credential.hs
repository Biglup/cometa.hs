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
{-# LANGUAGE RoleAnnotations #-}

-- | Role-specific credentials for payments, staking, governance and guards.
-- Hashes contain exactly 28 bytes. Equality and ordering compare kind and bytes;
-- diagnostic 'Show' output is not an interchange encoding.
--
-- @
-- import qualified Cometa.Credential as Credential
-- import qualified Cometa.Error
-- import qualified Data.ByteString as ByteString
--
-- payment :: Either Cometa.Error.Error (Credential.Credential Credential.Payment)
-- payment = Credential.KeyCredential <$> Credential.keyHashFromBytes (ByteString.replicate 28 0)
-- @
module Cometa.Credential
  ( Payment,
    Stake,
    Guard,
    DRep,
    CommitteeHot,
    CommitteeCold,
    Genesis,
    GenesisDelegate,
    StakePool,
    KeyHash,
    keyHashFromBytes,
    keyHashBytes,
    ScriptHash,
    scriptHashFromBytes,
    scriptHashBytes,
    Credential (..),
    fromPublicKey,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import Cometa.Error (Error (InvalidCredentialHashLength))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString

-- TYPES ----------------------------------------------------------------------

-- | Role of a payment key or credential.
data Payment

-- | Role of a staking key or credential.
data Stake

-- | Role of a Dijkstra transaction guard credential.
data Guard

-- | Role of a delegated representative's voting credential.
data DRep

-- | Role of a constitutional committee member's voting credential.
data CommitteeHot

-- | Role of a constitutional committee member's authorization credential.
data CommitteeCold

-- | Role of a genesis key authorizing delegation or a legacy protocol update.
data Genesis

-- | Role of a delegate authorized by a genesis key.
data GenesisDelegate

-- | Role of a stake pool operator's key hash.
data StakePool

-- | A 28-byte key hash. Hashes in different roles are distinct types;
-- importing bytes assigns their role.
type role KeyHash nominal

newtype KeyHash purpose = KeyHash ByteString deriving (Eq, Ord, Show)

-- | A 28-byte script hash, usable in any credential role.
newtype ScriptHash = ScriptHash ByteString deriving (Eq, Ord, Show)

-- | A key or script controlling the role selected by the type parameter.
-- Ordering places key credentials before script credentials, then compares bytes.
type role Credential nominal

data Credential purpose
  = -- | Authority identified by a key hash in this role.
    KeyCredential !(KeyHash purpose)
  | -- | Authority identified by a script hash.
    ScriptCredential !ScriptHash
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import a key hash without hashing. Any length except 28 returns
-- 'InvalidCredentialHashLength' with the actual byte count.
keyHashFromBytes :: ByteString -> Either Error (KeyHash purpose)
keyHashFromBytes bytes = KeyHash <$> validateHash bytes

-- | Exact key-hash bytes.
keyHashBytes :: KeyHash purpose -> ByteString
keyHashBytes (KeyHash bytes) = bytes

-- | Import a script hash without hashing. Any length except 28 returns
-- 'InvalidCredentialHashLength' with the actual byte count.
scriptHashFromBytes :: ByteString -> Either Error ScriptHash
scriptHashFromBytes bytes = ScriptHash <$> validateHash bytes

-- | Exact script-hash bytes.
scriptHashBytes :: ScriptHash -> ByteString
scriptHashBytes (ScriptHash bytes) = bytes

validateHash :: ByteString -> Either Error ByteString
validateHash bytes
  | ByteString.length bytes == 28 = Right bytes
  | otherwise = Left (InvalidCredentialHashLength (ByteString.length bytes))

-- | Hash a verification key using BLAKE2b-224 and assign the requested role.
-- The caller selects the credential role through the result type. Native failures
-- return 'Cometa.Error.NativeError'; unexpected digest lengths return
-- 'Cometa.Error.NativeContractViolation'.
fromPublicKey :: PublicKey.PublicKey -> IO (Either Error (Credential purpose))
fromPublicKey publicKey = fmap (fmap (KeyCredential . KeyHash . Blake2b.toBytes)) (PublicKey.hash publicKey)
