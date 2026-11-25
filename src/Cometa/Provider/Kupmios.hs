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

-- | Kupo indexing with Ogmios v6 HTTP queries, evaluation and submission.
-- Kupo must index every address/asset queried and retain transaction history for
-- confirmation checks. An empty result describes that index, not the entire chain.
-- Each response is bounded to 8 MiB; submission is explicit and never retried.
--
-- @
-- withProvider (defaultConfig Preprod "http://localhost:1442" "http://localhost:1337") $ \provider ->
--   Cometa.Provider.protocolParameters provider
-- @
module Cometa.Provider.Kupmios (Network (..), ApiKey, mkApiKey, Config (..), defaultConfig, withProvider) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error)
import Cometa.Provider (Provider)
import qualified Cometa.Provider.Blockfrost.Internal.Config as HttpConfig
import qualified Cometa.Provider.Blockfrost.Internal.Http as Http
import Cometa.Provider.Internal.Config (ApiKey, Network (..), apiKeyBytes, mkApiKey, transportConfig)
import qualified Cometa.Provider.Internal.Remote as Remote
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | Explicit chain identity and separate HTTP(S) endpoints and credentials.
data Config = Config
  { -- | Chain identity; both services must use this chain.
    network :: !Network,
    -- | Absolute Kupo HTTP(S) endpoint, including an optional path prefix/query.
    kupoEndpoint :: !Text,
    -- | Absolute Ogmios v6 HTTP(S) endpoint, including an optional path prefix/query.
    ogmiosEndpoint :: !Text,
    -- | Optional bearer credential used only for Kupo.
    kupoApiKey :: !(Maybe ApiKey),
    -- | Optional bearer credential used only for Ogmios.
    ogmiosApiKey :: !(Maybe ApiKey),
    -- | Whole-request timeout in milliseconds, from 1 through 60000.
    responseTimeoutMillis :: !Int,
    -- | Confirmation poll interval in milliseconds, from 1 through 60000.
    pollIntervalMillis :: !Int
  }

-- DEFINITIONS ----------------------------------------------------------------

-- | Explicit endpoints, no credentials, 30-second timeout and one-second polling.
defaultConfig :: Network -> Text -> Text -> Config
defaultConfig selected kupo ogmios = Config selected kupo ogmios Nothing Nothing 30000 1000

-- | Validate both configurations and scope both connection pools. Cancellation
-- propagates after cleanup. Operations on an escaped provider return RuntimeClosed.
withProvider :: Config -> (Provider -> IO (Either Error a)) -> IO (Either Error a)
withProvider config action = case HttpConfig.validateConfig kupo >> HttpConfig.validateConfig ogmios of
  Left failure -> pure (Left failure)
  Right () -> Http.withHeaders kupo (headers (kupoApiKey config)) $ \indexer ->
    Http.withHeaders ogmios (headers (ogmiosApiKey config)) $ \node ->
      action (Remote.provider Remote.Kupmios kupo indexer node)
  where
    settings url = transportConfig (network config) url (responseTimeoutMillis config) (pollIntervalMillis config)
    kupo = settings (kupoEndpoint config)
    ogmios = settings (ogmiosEndpoint config)
    headers credential = [("Authorization", "Bearer " <> apiKeyBytes key) | Just key <- [credential]]
