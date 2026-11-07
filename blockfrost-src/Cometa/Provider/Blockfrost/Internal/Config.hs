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
{-# OPTIONS_HADDOCK hide #-}

-- | Validated project credentials and bounded HTTP schedules.
module Cometa.Provider.Blockfrost.Internal.Config
  ( Network (..),
    ProjectId,
    mkProjectId,
    Config (..),
    defaultConfig,
    validateConfig,
    baseUrl,
    networkMagic,
    projectIdBytes,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Data.ByteString (ByteString)
import Data.Char (isAlphaNum, isAscii)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word32)

-- TYPES ----------------------------------------------------------------------

-- | Official Blockfrost Cardano network. Endpoints use verified HTTPS.
data Network
  = -- | Cardano mainnet, with network magic 764824073.
    Mainnet
  | -- | Pre-production test network, with network magic 1.
    Preprod
  | -- | Preview test network, with network magic 2.
    Preview
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | An opaque API credential. No printable instance exposes its contents.
newtype ProjectId = ProjectId ByteString deriving (Eq)

-- | HTTP and confirmation-poll settings. Validate once with @withProvider@.
-- Millisecond durations must be between 1 and 60,000 inclusive.
data Config = Config
  { -- | Official network endpoint and network magic.
    network :: !Network,
    -- | Project credential, sent only in the HTTP project_id header.
    projectId :: !ProjectId,
    -- | Whole-request deadline, in milliseconds, from 1 through 60000.
    responseTimeoutMillis :: !Int,
    -- | Delay between confirmation polls, in milliseconds, from 1 through 60000.
    pollIntervalMillis :: !Int
  }

-- DEFINITIONS ----------------------------------------------------------------

-- | Import 1 through 128 ASCII letters, digits, hyphens or underscores.
-- Whitespace and header delimiters are rejected without echoing the input.
mkProjectId :: Text -> Either Error ProjectId
mkProjectId value
  | Text.null value || Text.length value > 128 || not (Text.all allowed value) =
      Left (InvalidProviderConfiguration "Project identifier must contain 1 through 128 ASCII letters, digits, hyphens or underscores")
  | otherwise = Right (ProjectId (Text.encodeUtf8 value))
  where
    allowed character = isAscii character && (isAlphaNum character || character == '-' || character == '_')

-- | A 30-second whole-request timeout and a one-second confirmation poll period.
defaultConfig :: Network -> ProjectId -> Config
defaultConfig selected credential = Config selected credential 30000 1000

validateConfig :: Config -> Either Error ()
validateConfig config
  | invalid (responseTimeoutMillis config) = Left (InvalidProviderConfiguration "HTTP timeout must be between 1 and 60000 milliseconds")
  | invalid (pollIntervalMillis config) = Left (InvalidProviderConfiguration "Polling interval must be between 1 and 60000 milliseconds")
  | otherwise = Right ()
  where
    invalid value = value < 1 || value > 60000

baseUrl :: Network -> String
baseUrl selected = case selected of
  Mainnet -> "https://cardano-mainnet.blockfrost.io/api/v0"
  Preprod -> "https://cardano-preprod.blockfrost.io/api/v0"
  Preview -> "https://cardano-preview.blockfrost.io/api/v0"

networkMagic :: Network -> Word32
networkMagic selected = case selected of
  Mainnet -> 764824073
  Preprod -> 1
  Preview -> 2

projectIdBytes :: ProjectId -> ByteString
projectIdBytes (ProjectId bytes) = bytes
