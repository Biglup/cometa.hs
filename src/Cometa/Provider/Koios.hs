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

-- | Scoped Koios queries and explicit submission through the ordinary Provider
-- record. Responses are bounded to 8 MiB. Submission is never retried.
-- Confirmation observes block inclusion, not finality. Evaluation uses the
-- Conway-era service dialect and requires budgets for every existing redeemer.
--
-- @
-- withProvider (defaultConfig Preprod (Just credential)) $ \provider ->
--   Cometa.Provider.protocolParameters provider
-- @
module Cometa.Provider.Koios (Network (..), ApiKey, mkApiKey, Config (..), defaultConfig, withProvider) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Provider (Provider)
import qualified Cometa.Provider.Blockfrost.Internal.Config as HttpConfig
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import Cometa.Provider.Internal.Config (ApiKey, Network (..), apiKeyBytes, mkApiKey, transportConfig)
import qualified Cometa.Provider.Internal.Remote as Remote
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | Explicit chain, endpoint, credentials and bounded timing settings.
-- No environment variables or files are read implicitly.
data Config = Config
  { -- | Chain identity, independent of the custom endpoint.
    network :: !Network,
    -- | Absolute HTTP(S) URL. No user information or fragment is accepted.
    -- Base path and query parameters are retained; operation queries win.
    endpoint :: !Text,
    -- | Optional credential; Nothing supports an unauthenticated proxy.
    apiKey :: !(Maybe ApiKey),
    -- | Whole-request timeout in milliseconds, from 1 through 60000.
    responseTimeoutMillis :: !Int,
    -- | Confirmation poll interval in milliseconds, from 1 through 60000.
    pollIntervalMillis :: !Int
  }

-- DEFINITIONS ----------------------------------------------------------------

-- | Official endpoint, 30-second request timeout and one-second poll interval.
defaultConfig :: Network -> Maybe ApiKey -> Config
defaultConfig selected credential = Config selected url credential 30000 1000
  where
    url = case selected of Mainnet -> "https://api.koios.rest/api/v1"; Preprod -> "https://preprod.koios.rest/api/v1"; Preview -> "https://preview.koios.rest/api/v1"

-- | Validate configuration, acquire a scoped connection pool and run a workflow.
-- Scope exit drains active requests; cancellation propagates after cleanup.
-- An escaped provider returns RuntimeClosed without opening a connection.
withProvider :: Config -> (Provider -> IO (Either Error a)) -> IO (Either Error a)
withProvider config action = case HttpConfig.validateConfig settings of
  Left failure -> pure (Left failure)
  Right () -> Http.withHeaders settings headers $ \transport ->
    action (Remote.provider Remote.Koios settings transport transport)
  where
    settings = transportConfig (network config) (endpoint config) (responseTimeoutMillis config) (pollIntervalMillis config)
    headers = [("Authorization", "Bearer " <> apiKeyBytes key) | Just key <- [apiKey config]]
