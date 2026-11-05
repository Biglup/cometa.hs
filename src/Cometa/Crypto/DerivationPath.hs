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

-- | Validated five-level wallet paths: @m / purpose' / coin_type' / account' /
-- role / index@. Components are unencoded numbers; the first three become
-- hardened when converted to BIP32 indices. Custom purposes, coins and roles
-- are supported within the same bounds as standard paths.
--
-- @
-- import qualified Cometa.Crypto.DerivationPath as Path
--
-- firstAccount :: Path.AccountPath
-- firstAccount = Path.standardAccountPath minBound
-- @
module Cometa.Crypto.DerivationPath
  ( -- * Components
    Index,
    mkIndex,
    indexValue,

    -- * Account paths
    AccountPath,
    accountPath,
    purpose,
    coinType,
    account,
    accountIndices,

    -- * Key paths
    DerivationPath,
    derivationPath,
    accountPrefix,
    role,
    index,
    toIndices,
    relativeIndices,

    -- * Cardano wallet components
    cardanoCoinType,
    standardPurpose,
    multisigPurpose,
    externalRole,
    internalRole,
    stakingRole,
    drepRole,
    committeeColdRole,
    committeeHotRole,
    standardAccountPath,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (InvalidDerivationIndex))
import Data.Bits ((.|.))
import Data.Word (Word32)

-- TYPES ----------------------------------------------------------------------

-- | An unencoded component in @0..2147483647@. Equality and ordering compare
-- the component number; 'Show' is diagnostic. 'minBound' is zero and 'maxBound'
-- is 2147483647.
newtype Index = Index Word32 deriving (Eq, Ord, Show)

instance Bounded Index where
  minBound = Index 0
  maxBound = Index 2147483647

-- | Three unencoded components in purpose, coin type, account order.
-- Equality and ordering compare components in that order; 'Show' is diagnostic.
data AccountPath = AccountPath !Index !Index !Index deriving (Eq, Ord, Show)

-- | An account prefix followed by an unhardened role and key index.
-- Equality and ordering compare all five components in derivation order;
-- 'Show' is diagnostic.
data DerivationPath = DerivationPath !AccountPath !Index !Index deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate an unencoded component. Negative values and values above
-- @2147483647@ return 'InvalidDerivationIndex', retaining the exact input.
mkIndex :: Integer -> Either Error Index
mkIndex value
  | value < 0 || value > 2147483647 = Left (InvalidDerivationIndex value)
  | otherwise = Right (Index (fromInteger value))

-- | The unencoded component number, without the hardening bit.
indexValue :: Index -> Word32
indexValue (Index value) = value

-- | Construct an account prefix from purpose, coin type and account number.
-- All three components will be hardened by 'accountIndices'.
accountPath :: Index -> Index -> Index -> AccountPath
accountPath = AccountPath

-- | Unencoded purpose number, for example 1852 or 1854.
purpose :: AccountPath -> Index
purpose (AccountPath value _ _) = value

-- | Unencoded coin type, for example 1815 for Cardano.
coinType :: AccountPath -> Index
coinType (AccountPath _ value _) = value

-- | Unencoded account number, numbered from zero.
account :: AccountPath -> Index
account (AccountPath _ _ value) = value

-- | Three encoded hardened indices in derivation order, suitable for private
-- BIP32 derivation from a root key. Each has its high bit set.
accountIndices :: AccountPath -> [Word32]
accountIndices path = map ((.|. 0x80000000) . indexValue) [purpose path, coinType path, account path]

-- | Extend an account prefix with an unhardened role and key index, in that order.
derivationPath :: AccountPath -> Index -> Index -> DerivationPath
derivationPath = DerivationPath

-- | The three-component account prefix.
accountPrefix :: DerivationPath -> AccountPath
accountPrefix (DerivationPath value _ _) = value

-- | Unhardened role number. Standard roles are named in this module.
role :: DerivationPath -> Index
role (DerivationPath _ value _) = value

-- | Unhardened key index, numbered from zero.
index :: DerivationPath -> Index
index (DerivationPath _ _ value) = value

-- | Five encoded indices in derivation order, suitable for private BIP32
-- derivation from the root. Only the first three indices are hardened.
toIndices :: DerivationPath -> [Word32]
toIndices path = accountIndices (accountPrefix path) ++ relativeIndices path

-- | The two unhardened indices, role then key index, relative to an already
-- derived account key. Suitable for private or public BIP32 derivation.
relativeIndices :: DerivationPath -> [Word32]
relativeIndices path = map indexValue [role path, index path]

-- Values audited against key_handlers/cip_1852_constants.h at native revision
-- 7811fe94dad90f30478ed4b61d96677f188abaa8; native-oracle tests verify agreement.

-- | Cardano coin type.
cardanoCoinType :: Index
cardanoCoinType = Index 1815

-- | Standard wallet purpose.
standardPurpose :: Index
standardPurpose = Index 1852

-- | CIP-1854 multisignature wallet purpose.
multisigPurpose :: Index
multisigPurpose = Index 1854

-- | External payment chain role.
externalRole :: Index
externalRole = Index 0

-- | Internal change chain role.
internalRole :: Index
internalRole = Index 1

-- | Staking key role (CIP-0011).
stakingRole :: Index
stakingRole = Index 2

-- | Delegated representative key role (CIP-0105).
drepRole :: Index
drepRole = Index 3

-- | Constitutional committee cold key role (CIP-0105).
committeeColdRole :: Index
committeeColdRole = Index 4

-- | Constitutional committee hot key role (CIP-0105).
committeeHotRole :: Index
committeeHotRole = Index 5

-- | Standard Cardano account prefix for the supplied unencoded account number.
-- Uses purpose 1852 and coin type 1815. For multisignature or custom purposes,
-- use 'accountPath' with the desired components.
standardAccountPath :: Index -> AccountPath
standardAccountPath = accountPath standardPurpose cardanoCoinType
