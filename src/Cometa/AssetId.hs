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

-- | Ada and native assets with validated policy and name components.
--
-- @
-- import qualified Cometa.AssetId as AssetId
-- import qualified Cometa.AssetName as AssetName
-- import qualified Cometa.PolicyId as PolicyId
--
-- unnamedToken :: PolicyId.PolicyId -> AssetId.AssetId
-- unnamedToken policy = AssetId.Native policy AssetName.empty
-- @
module Cometa.AssetId
  ( AssetId (..),
    fromBytes,
    toBytes,
    fromHex,
    toHex,
    fingerprint,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.Binary.Bech32 as Bech32
import Cometa.AssetName (AssetName)
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import Cometa.PolicyId (PolicyId)
import qualified Cometa.PolicyId as PolicyId
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | An asset's identity. Ordering places Ada first, then compares native policy
-- bytes and name bytes lexicographically. 'Show' is diagnostic output.
data AssetId
  = -- | Ada; its quantity is measured in lovelace (one millionth of an Ada).
    Ada
  | -- | A native asset, identified by policy and exact name bytes. An empty
    -- name under a policy is a native asset, distinct from Ada.
    Native !PolicyId !AssetName
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Import a native asset as its 28-byte policy followed by zero through 32
-- exact name bytes. Other lengths, including empty input, return
-- 'InvalidAssetIdLength'. Ada has no encoding in this format.
fromBytes :: ByteString -> Either Error AssetId
fromBytes bytes
  | size < 28 || size > 60 = Left (InvalidAssetIdLength size)
  | otherwise = Native <$> PolicyId.fromBytes policy <*> AssetName.fromBytes name
  where
    size = ByteString.length bytes
    (policy, name) = ByteString.splitAt 28 bytes

-- | Export the policy bytes followed by the exact name bytes. Ada returns
-- 'UnsupportedOperation'; an empty native name still exports 28 policy bytes.
toBytes :: AssetId -> Either Error ByteString
toBytes Ada = Left (UnsupportedOperation "AssetId.toBytes: Ada has no native asset encoding")
toBytes (Native policy name) = Right (PolicyId.toBytes policy <> AssetName.toBytes name)

-- | Import 56 through 120 ASCII hexadecimal digits as a native asset.
-- Either case is accepted, without a prefix or whitespace. Malformed hex
-- returns 'InvalidHex'; other decoded lengths return 'InvalidAssetIdLength'.
-- Empty text does not represent Ada.
fromHex :: Text -> Either Error AssetId
fromHex text = maybe (Left InvalidHex) fromBytes (Hex.decodeHex text)

-- | Export the native asset as lowercase hexadecimal policy and name bytes,
-- without a separator. Ada returns 'UnsupportedOperation'.
toHex :: AssetId -> Either Error Text
toHex asset = Hex.encodeHex <$> toBytes asset

-- | Compute the CIP-14 user-facing native asset fingerprint: BLAKE2b-160 of
-- the policy followed by the exact name bytes, encoded as Bech32 with the
-- @asset@ prefix. Ada returns 'UnsupportedOperation'. Hashing failures return
-- the corresponding 'NativeError'.
--
-- The fingerprint is a display checksum. It cannot be decoded back to the policy
-- and name, and does not replace the full asset identity or prove authenticity.
fingerprint :: AssetId -> IO (Either Error Text)
fingerprint Ada = pure (Left (UnsupportedOperation "AssetId.fingerprint: Ada has no CIP-14 fingerprint"))
fingerprint asset = case toBytes asset of
  Left failure -> pure (Left failure)
  Right bytes -> do
    hashed <- Blake2b.compute 20 bytes
    pure $ do
      digest <- hashed
      prefix <- either (const (Left (NativeContractViolation "Invalid built-in asset fingerprint prefix"))) Right (Bech32.humanReadablePartFromText "asset")
      pure (Bech32.encodeLenient prefix (Bech32.dataPartFromBytes (Blake2b.toBytes digest)))
