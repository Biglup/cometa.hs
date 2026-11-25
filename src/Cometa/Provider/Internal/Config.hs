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

-- | Validated credentials and shared transport settings.
module Cometa.Provider.Internal.Config (Network (..), ApiKey, mkApiKey, apiKeyBytes, transportConfig) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Provider.Blockfrost.Internal.Config (Network (..))
import qualified Cometa.Provider.Blockfrost.Internal.Config as Http
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

-- DEFINITIONS ----------------------------------------------------------------

-- | Opaque HTTP credential. Its contents have no printable instance.
newtype ApiKey = ApiKey ByteString deriving (Eq)

-- | Validate 1 through 4096 printable ASCII characters, excluding whitespace.
-- This accepts opaque API keys and bearer tokens without exposing diagnostics.
mkApiKey :: Text -> Either Error ApiKey
mkApiKey value
  | Text.null value || Text.length value > 4096 || not (Text.all (\c -> c >= '!' && c <= '~') value) = Left (InvalidProviderConfiguration "Invalid API credential")
  | otherwise = Right (ApiKey (Text.encodeUtf8 value))

apiKeyBytes :: ApiKey -> ByteString
apiKeyBytes (ApiKey bytes) = bytes

transportConfig :: Network -> Text -> Int -> Int -> Http.Config
transportConfig network endpoint = Http.Config network endpoint Nothing
