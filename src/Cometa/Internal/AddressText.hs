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

-- | Pure Bech32 address encoding. The four fixed HRPs are validated by their
-- literal contents and tests. The sole invariant assertion checks four
-- source-controlled literals using the public package validator; it cannot be
-- reached from external input. No arbitrary HRP enters encoding.
module Cometa.Internal.AddressText (fromText, toText) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.Binary.Bech32 as Bech32
import Cometa.Error (Error (..))
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text

-- TYPES ----------------------------------------------------------------------

data Prefix = PaymentMainnet | PaymentTestnet | RewardMainnet | RewardTestnet

-- DEFINITIONS ----------------------------------------------------------------

toText :: Bool -> Bool -> ByteString -> Text
toText reward mainnet = Bech32.encodeLenient prefix . Bech32.dataPartFromBytes
  where
    prefix = case (reward, mainnet) of
      (False, True) -> paymentMainnetPrefix
      (False, False) -> paymentTestnetPrefix
      (True, True) -> rewardMainnetPrefix
      (True, False) -> rewardTestnetPrefix

-- Only these four static literals reach the assertion. Tests validate all four
-- through the public package API and pinned native text vectors.

paymentMainnetPrefix, paymentTestnetPrefix, rewardMainnetPrefix, rewardTestnetPrefix :: Bech32.HumanReadablePart
paymentMainnetPrefix = builtInPrefix PaymentMainnet
paymentTestnetPrefix = builtInPrefix PaymentTestnet
rewardMainnetPrefix = builtInPrefix RewardMainnet
rewardTestnetPrefix = builtInPrefix RewardTestnet

builtInPrefix :: Prefix -> Bech32.HumanReadablePart
builtInPrefix prefix = case Bech32.humanReadablePartFromText literal of
  Right value -> value
  Left _ -> error "Cometa: invalid built-in Bech32 prefix"
  where
    literal = case prefix of
      PaymentMainnet -> "addr"
      PaymentTestnet -> "addr_test"
      RewardMainnet -> "stake"
      RewardTestnet -> "stake_test"

fromText :: (ByteString -> Either Error address) -> (address -> Text) -> Text -> Either Error address
fromText parse encode text
  | Text.null text || Text.length text > 120 || Text.any (\character -> character < '!' || character > '~') text || (Text.toLower text /= text && Text.toUpper text /= text) = Left InvalidShelleyAddressText
  | otherwise = do
      (_, payload) <- either (const (Left InvalidShelleyAddressText)) Right (Bech32.decodeLenient text)
      bytes <- maybe (Left InvalidShelleyAddressText) Right (Bech32.dataPartToBytes payload)
      address <- parse bytes
      if encode address == Text.toLower text
        then Right address
        else Left InvalidShelleyAddressText
