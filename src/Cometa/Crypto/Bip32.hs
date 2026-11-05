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

-- | Derive Cardano Ed25519-BIP32 public keys from BIP39 entropy and validated
-- wallet paths. Passwords are raw bytes, without text normalization. These
-- operations accept entropy, not a mnemonic sentence or a 64-byte BIP39 seed.
--
-- @
-- import qualified Cometa.Crypto.Bip32 as Bip32
-- import qualified Cometa.Crypto.DerivationPath as Path
--
-- firstAccount password entropy =
--   Bip32.deriveAccountPublicKey password entropy (Path.standardAccountPath minBound)
-- @
module Cometa.Crypto.Bip32
  ( deriveAccountPublicKey,
    derivePublicKey,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PrivateKey as PrivateKey
import Cometa.Crypto.Bip32.PublicKey (PublicKey)
import Cometa.Crypto.DerivationPath (AccountPath, DerivationPath)
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error)
import Data.ByteString (ByteString)
import Data.Word (Word32)

-- DEFINITIONS ----------------------------------------------------------------

-- | Derive an extended account public key from password bytes, BIP39 entropy
-- bytes and an account path, respectively. Entropy must contain 16, 20, 24, 28
-- or 32 bytes; other lengths return @InvalidBip39EntropyLength@. Passwords may
-- be empty or contain NUL bytes. Native failures return @NativeError@. The result
-- includes the chain code and supports public derivation of role/index suffixes.
deriveAccountPublicKey :: ByteString -> ByteString -> AccountPath -> IO (Either Error PublicKey)
deriveAccountPublicKey password entropy path = deriveIndices password entropy (Path.accountIndices path)

-- | Derive an extended public key from password bytes, BIP39 entropy bytes and
-- a five-component wallet path, respectively. Entropy and passwords follow
-- 'deriveAccountPublicKey'; native failures return @NativeError@. The result
-- includes the chain code and remains usable after this operation returns.
derivePublicKey :: ByteString -> ByteString -> DerivationPath -> IO (Either Error PublicKey)
derivePublicKey password entropy path = deriveIndices password entropy (Path.toIndices path)

deriveIndices :: ByteString -> ByteString -> [Word32] -> IO (Either Error PublicKey)
deriveIndices password entropy indices =
  PrivateKey.withEntropy password entropy $ \root ->
    PrivateKey.withDerived root indices PrivateKey.publicKey
