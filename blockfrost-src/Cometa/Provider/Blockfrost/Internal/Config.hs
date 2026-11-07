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

-- | Endpoint and credential configuration with bounded HTTP schedules.
module Cometa.Provider.Blockfrost.Internal.Config
  ( Network (..),
    ProjectId,
    mkProjectId,
    Config (..),
    defaultConfig,
    validateConfig,
    parseEndpoint,
    baseUrl,
    networkMagic,
    projectIdBytes,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Control.Monad (foldM, void)
import Data.ByteString (ByteString)
import Data.Char (isAlphaNum, isAscii, isDigit, ord)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word32)
import qualified Network.HTTP.Client as Http
import qualified Network.URI as URI

-- TYPES ----------------------------------------------------------------------

-- | Cardano chain identity. A custom endpoint does not change its network magic.
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
  { -- | Chain identity and network magic, independent of the endpoint URL.
    network :: !Network,
    -- | Absolute HTTP or HTTPS base URL, including any path prefix and query
    -- parameters. User information and fragments are not supported. Operation
    -- query parameters override base parameters with the same name.
    endpoint :: !Text,
    -- | Optional project credential. 'Nothing' omits the project_id header.
    projectId :: !(Maybe ProjectId),
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

-- | The network's official HTTPS endpoint, a 30-second whole-request timeout,
-- and a one-second confirmation poll period. Supply 'Nothing' when the endpoint
-- does not require a project credential; set 'endpoint' for a custom service.
defaultConfig :: Network -> Maybe ProjectId -> Config
defaultConfig selected credential = Config selected (Text.pack (baseUrl selected)) credential 30000 1000

validateConfig :: Config -> Either Error ()
validateConfig config
  | invalid (responseTimeoutMillis config) = Left (InvalidProviderConfiguration "HTTP timeout must be between 1 and 60000 milliseconds")
  | invalid (pollIntervalMillis config) = Left (InvalidProviderConfiguration "Polling interval must be between 1 and 60000 milliseconds")
  | otherwise = void (parseEndpoint (endpoint config))
  where
    invalid value = value < 1 || value > 60000

-- | The standard URI parser handles authority, percent escapes and bracketed
-- IPv6. The HTTP client's pure conversion checks its supported schemes and port
-- representation. Neither parser's diagnostic is exposed: URLs can contain query
-- credentials, and userinfo would install implicit Basic authentication.
parseEndpoint :: Text -> Either Error Http.Request
parseEndpoint value = case URI.parseURI (Text.unpack value) of
  Just uri
    | Just authority <- URI.uriAuthority uri,
      not (null (URI.uriRegName authority)),
      null (URI.uriUserInfo authority),
      validPort (URI.uriPort authority),
      null (URI.uriFragment uri) -> case Http.requestFromURI uri :: Maybe Http.Request of
        Just request | Http.port request >= 1 && Http.port request <= 65535 -> Right request
        _ -> invalidEndpoint
  _ -> invalidEndpoint
  where
    invalidEndpoint = Left (InvalidProviderConfiguration "Endpoint must be an absolute HTTP or HTTPS URL with a host and valid port, without user information or a fragment")

-- Validate the URI authority's decimal port before the client's Int conversion:
-- http-client 0.7.19 uses Read Int, which can wrap excessively large values.
-- The accumulator never exceeds 65535, including with arbitrarily many zeros.
validPort :: String -> Bool
validPort "" = True
validPort (':' : digits) =
  not (null digits) && case foldM digit 0 digits of
    Just value -> value >= 1
    Nothing -> False
  where
    digit :: Int -> Char -> Maybe Int
    digit current character
      | isDigit character && next <= 65535 = Just next
      | otherwise = Nothing
      where
        next = current * 10 + ord character - ord '0'
validPort _ = False

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
