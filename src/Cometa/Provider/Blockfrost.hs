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

-- | A scoped Blockfrost backend for the ordinary 'Provider' record. Queries
-- return domain values and report explicit errors. Pagination uses ascending
-- pages of 100 results, rejects repeated identities, and permits at most 10000
-- pages per query. Independent requests do not form an atomic ledger snapshot.
--
-- Submission is explicit and never retried automatically. Confirmation means
-- the transaction appears in a block; it does not establish finality. Remote
-- evaluation uses the documented Ogmios v5 dialect: V1/V2 scripts and spending,
-- minting, certificate and withdrawal purposes. Unsupported newer features fail
-- explicitly; local "Cometa.Evaluation.Native" supports the binding's native VM.
--
-- @
-- withProvider (defaultConfig Preview (Just project)) $ \provider ->
--   Cometa.Provider.utxosAt provider address
-- @
module Cometa.Provider.Blockfrost
  ( Network (..),
    ProjectId,
    mkProjectId,
    Config (..),
    defaultConfig,
    withProvider,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Provider (Provider)
import Cometa.Provider.Blockfrost.Internal.Config (Config (..), Network (..), ProjectId, defaultConfig, mkProjectId)
import qualified Cometa.Provider.Blockfrost.Internal.Config as Config
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import Cometa.Provider.Blockfrost.Internal.Provider (providerWithTransport)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate an absolute HTTP or HTTPS endpoint and configuration, share one
-- scoped HTTP transport, and run a caller workflow with one expected-error
-- boundary. Supply credentials from application configuration, or omit them for
-- a service that does not require authentication. Custom path prefixes and base
-- query parameters are retained; operation
-- query parameters take precedence. No environment variables or files are read
-- implicitly. Escaped provider operations fail with
-- 'Cometa.Error.RuntimeClosed' after the scope.
-- Scope exit waits for active requests; cancellation propagates after cleanup.
withProvider :: Config -> (Provider -> IO (Either Error a)) -> IO (Either Error a)
withProvider config action = case Config.validateConfig config of
  Left failure -> pure (Left failure)
  Right () -> Http.withTransport config (action . providerWithTransport config)
