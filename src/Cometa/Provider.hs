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

-- | Inject blockchain queries and explicit transaction effects as ordinary IO
-- functions. Missing values use Maybe, successful empty queries use empty lists,
-- and expected failures use Either. These independent observations do not imply
-- an atomic ledger snapshot. Operations never submit a transaction implicitly.
--
-- @
-- fake = (unavailable "Offline fixture" 42) {utxosAt = \_ -> pure (Right [])}
-- @
module Cometa.Provider (Provider (..), unavailable) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Address (Address)
import Cometa.Address.Reward (RewardAddress)
import Cometa.AssetId (AssetId)
import Cometa.Error (Error (..))
import Cometa.Evaluation (Budgets)
import Cometa.PlutusData (EncodedPlutusData)
import Cometa.Protocol.Parameters (Parameters)
import Cometa.Transaction (Transaction)
import Cometa.Transaction.Datum (Hash32)
import Cometa.Transaction.Input (Input)
import Cometa.Transaction.Utxo (Utxo)
import Cometa.TransactionId (TransactionId)
import Data.Text (Text)
import Data.Word (Word32, Word64)

-- TYPES ----------------------------------------------------------------------

-- | An application-supplied backend. Fields may perform network effects, use a
-- local cache or return deterministic fixtures. Exceptions propagate normally;
-- expected backend failures belong in Left. No equality or Show instance is
-- defined for function-valued capabilities.
data Provider = Provider
  { -- | Diagnostic name. When used in Cometa operations, supply at most 255
    -- UTF-8 bytes and no NUL character. The name is not a credential or endpoint URL.
    name :: !Text,
    -- | Network magic, distinct from a four-bit address network identifier.
    networkMagic :: !Word32,
    -- | Complete protocol snapshot; optional era fields retain availability.
    protocolParameters :: IO (Either Error Parameters),
    -- | Unspent outputs at an address. Empty is a successful no-match query.
    utxosAt :: Address -> IO (Either Error [Utxo]),
    -- | Current reward balance, in lovelace from zero through 2^64 - 1.
    rewardBalance :: RewardAddress -> IO (Either Error Word64),
    -- | Unspent outputs at the address containing the specified asset.
    utxosWithAsset :: Address -> AssetId -> IO (Either Error [Utxo]),
    -- | The unique output containing an asset assumed to be an NFT. Nothing
    -- means absent; ambiguous matches must return an expected backend failure.
    utxoWithAsset :: AssetId -> IO (Either Error (Maybe Utxo)),
    -- | Resolve references. Missing inputs are omitted, not turned into errors;
    -- callers needing complete resolution must check every requested reference.
    resolveInputs :: [Input] -> IO (Either Error [Utxo]),
    -- | Resolve exact datum bytes. Nothing means the datum is unavailable.
    resolveDatum :: Hash32 -> IO (Either Error (Maybe EncodedPlutusData)),
    -- | Wait up to the supplied timeout in milliseconds. False means not
    -- confirmed within that interval; transport failures remain Left.
    awaitTransaction :: TransactionId -> Word64 -> IO (Either Error Bool),
    -- | Explicitly submit exact transaction bytes and return the accepted ID.
    -- A successful result does not claim confirmation or finality.
    submitTransaction :: Transaction -> IO (Either Error TransactionId),
    -- | Evaluate top-level redeemers with additional resolved UTxOs. Return
    -- budgets for every existing top-level purpose/index without changing input.
    -- No partial-success or evaluation-log information is implied.
    evaluateTransaction :: Transaction -> [Utxo] -> IO (Either Error Budgets)
  }

-- DEFINITIONS ----------------------------------------------------------------

-- | Total default backend with explicit metadata. Override only the capabilities
-- required by a workflow. Every operation initially returns UnsupportedOperation
-- naming that operation; none acquires a connection or performs network work.
unavailable :: Text -> Word32 -> Provider
unavailable backendName magic =
  Provider
    backendName
    magic
    (unsupported "provider.protocolParameters")
    (\_ -> unsupported "provider.utxosAt")
    (\_ -> unsupported "provider.rewardBalance")
    (\_ _ -> unsupported "provider.utxosWithAsset")
    (\_ -> unsupported "provider.utxoWithAsset")
    (\_ -> unsupported "provider.resolveInputs")
    (\_ -> unsupported "provider.resolveDatum")
    (\_ _ -> unsupported "provider.awaitTransaction")
    (\_ -> unsupported "provider.submitTransaction")
    (\_ _ -> unsupported "provider.evaluateTransaction")
  where
    unsupported operation = pure (Left (UnsupportedOperation operation))
