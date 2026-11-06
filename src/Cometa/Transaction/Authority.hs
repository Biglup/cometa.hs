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

-- | Discover the unique direct key authorities of a top-level transaction.
-- Resolve spending and collateral inputs before requesting hashes, then select
-- the corresponding signing keys in the application's wallet.
--
-- @
-- import qualified Cometa.Transaction.Authority as Authority
--
-- discover transaction resolved = Authority.requiredKeyHashes transaction resolved
-- @
module Cometa.Transaction.Authority (requiredKeyHashes) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Crypto.Blake2b (Blake2bHash)
import Cometa.Error (Error)
import qualified Cometa.Internal.ContextualTransaction as Native
import Cometa.Transaction (Transaction)
import Cometa.Transaction.Utxo (Utxo)
import Data.Set (Set)

-- DEFINITIONS ----------------------------------------------------------------

-- | Unique 28-byte key hashes from top-level key guards, resolved spending and
-- collateral addresses, withdrawals, certificates and voters. The set has no
-- credential-role assignment. Every spending and collateral input must resolve;
-- duplicate resolution entries and missing references return an error. Extra
-- resolved outputs are allowed, and reference inputs need no resolution here.
--
-- Native scripts, script credentials, Byron bootstrap authorities and nested
-- transaction levels are excluded. This does not identify every key that could
-- satisfy arbitrary script logic, verify signatures, or validate ledger rules.
requiredKeyHashes :: Transaction -> [Utxo] -> IO (Either Error (Set Blake2bHash))
requiredKeyHashes = Native.requiredKeyHashes
