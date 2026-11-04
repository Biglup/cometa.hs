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
{-# OPTIONS_HADDOCK hide #-}

-- | Total ASCII hexadecimal conversion for immutable byte snapshots.
module Cometa.Internal.Hex (decodeHex, encodeHex) where

-- IMPORTS --------------------------------------------------------------------

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word8)

-- DEFINITIONS ----------------------------------------------------------------

-- | Decode pairs of ASCII digits, accepting either case. Empty text yields empty
-- bytes; odd lengths and nonhexadecimal characters fail without partial output.
decodeHex :: Text -> Maybe ByteString
decodeHex text = ByteString.pack <$> decodePairs [] (Text.unpack text)
  where
    decodePairs accumulated [] = Just (reverse accumulated)
    decodePairs accumulated (high : low : rest) = do
      first <- hexDigit high
      second <- hexDigit low
      decodePairs (first * 16 + second : accumulated) rest
    decodePairs _ [_] = Nothing

-- | Render each byte as two lowercase ASCII digits, without a prefix.
encodeHex :: ByteString -> Text
encodeHex = Text.pack . concatMap encodeByte . ByteString.unpack
  where
    encodeByte byte = [digit (byte `div` 16), digit (byte `mod` 16)]
    digit value
      | value < 10 = toEnum (fromIntegral value + fromEnum '0')
      | otherwise = toEnum (fromIntegral value - 10 + fromEnum 'a')

-- | Convert one ASCII hexadecimal digit without locale-sensitive parsing.
hexDigit :: Char -> Maybe Word8
hexDigit character
  | isDigit character = Just (offset '0')
  | character >= 'a' && character <= 'f' = Just (10 + offset 'a')
  | character >= 'A' && character <= 'F' = Just (10 + offset 'A')
  | otherwise = Nothing
  where
    offset start = fromIntegral (fromEnum character - fromEnum start)
