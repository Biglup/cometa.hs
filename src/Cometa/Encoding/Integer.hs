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

-- | Exact integer text, magnitude bytes and modular arithmetic. Values are
-- ordinary Haskell 'Integer's; no native object or mutable buffer is exposed.
--
-- Validate a 'Radix' once, parse text with 'fromText', then pass the integer to
-- metadata or Plutus-data constructors. 'fromTextAuto' recognizes native-style
-- radix prefixes. Modular operations report invalid domains through 'Either'.
module Cometa.Encoding.Integer
  ( Radix,
    mkRadix,
    radixValue,
    binary,
    decimal,
    hexadecimal,
    fromText,
    fromTextAuto,
    toText,
    toUpperText,
    ByteOrder (..),
    fromBytes,
    toBytes,
    modularInverse,
    modularPower,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.List (unfoldr)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showIntAtBase)

-- TYPES ----------------------------------------------------------------------

-- | A radix from 2 through 62. Above 36, uppercase digits precede lowercase.
newtype Radix = Radix Int deriving (Eq, Ord, Show)

-- | Order of unsigned magnitude bytes. Neither order carries a sign bit.
data ByteOrder = LittleEndian | BigEndian deriving (Eq, Ord, Show, Enum, Bounded)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate a radix; other values return 'InvalidIntegerRadix'.
mkRadix :: Int -> Either Error Radix
mkRadix n
  | n >= 2 && n <= 62 = Right (Radix n)
  | otherwise = Left (InvalidIntegerRadix n)

-- | Observe the validated radix.
radixValue :: Radix -> Int
radixValue (Radix n) = n

-- | Base 2.
binary :: Radix
binary = Radix 2

-- | Base 10.
decimal :: Radix
decimal = Radix 10

-- | Base 16.
hexadecimal :: Radix
hexadecimal = Radix 16

-- | Parse a native-compatible complete textual prefix: an optional minus sign,
-- digits, and ASCII whitespace. A plus sign and explicit radix prefixes are
-- rejected. Parsing stops at the first NUL. Letter case is ignored through
-- base 36; bases 37..62 use @0..9,A..Z,a..z@. Empty or invalid digits return
-- 'InvalidIntegerText'. Whitespace before the minus sign is accepted.
fromText :: Radix -> Text -> Either Error Integer
fromText (Radix radix) text = let (negative, digits) = signed text in parseDigits radix negative digits

-- | Detect base 16 from @0x@/@0X@, base 2 from @0b@/@0B@, base 8 from a
-- leading zero, and base 10 otherwise. Prefix detection follows the optional
-- minus sign before internal whitespace is removed, matching native base 0.
fromTextAuto :: Text -> Either Error Integer
fromTextAuto text =
  let (negative, digits) = signed text
      (radix, remaining) = case T.unpack (T.take 2 digits) of
        ['0', 'x'] -> (16, T.drop 2 digits)
        ['0', 'X'] -> (16, T.drop 2 digits)
        ['0', 'b'] -> (2, T.drop 2 digits)
        ['0', 'B'] -> (2, T.drop 2 digits)
        _ | T.isPrefixOf "0" digits -> (8, digits)
        _ -> (10, digits)
   in parseDigits radix negative remaining

-- | Render the exact integer without a radix prefix or whitespace. Bases
-- 2..36 use lowercase letters; bases 37..62 use @0..9,A..Z,a..z@. Zero is @0@.
-- The minus sign is outside the unsigned digit conversion.
toText :: Radix -> Integer -> Text
toText (Radix radix) number =
  T.pack ((if number < 0 then "-" else "") ++ showIntAtBase (toInteger radix) (digitCharacter radix) (abs number) "")

-- | Uppercase rendering for bases 2..36, equivalent to native negative
-- rendering bases -2..-36. Larger radices return 'InvalidIntegerRadix' with
-- the corresponding negative base, since changing case would change digits.
toUpperText :: Radix -> Integer -> Either Error Text
toUpperText radix number
  | radixValue radix > 36 = Left (InvalidIntegerRadix (negate (radixValue radix)))
  | otherwise = Right (T.toUpper (toText radix number))

-- | Decode unsigned magnitude bytes; empty input denotes zero. Leading zero
-- bytes are accepted. This is independent of host byte order.
fromBytes :: ByteOrder -> ByteString -> Integer
fromBytes order = B.foldl' (\n b -> n * 256 + toInteger b) 0 . ordered
  where
    ordered = case order of LittleEndian -> B.reverse; BigEndian -> id

-- | Minimal unsigned magnitude bytes of the absolute value. Zero has one
-- zero byte; positive and negative integers with the same magnitude agree.
toBytes :: ByteOrder -> Integer -> ByteString
toBytes order number =
  let little = if number == 0 then [0] else unfoldr step (abs number)
   in B.pack (case order of LittleEndian -> little; BigEndian -> reverse little)
  where
    step 0 = Nothing
    step n = let (q, r) = n `quotRem` 256 in Just (fromInteger r, q)

-- | Inverse in @[0,abs modulus)@. Moduli 0 and +/-1 return 'InvalidModulus';
-- zero or noncoprime values return 'NoModularInverse'. Unlike the native void
-- function, failure never leaves an unspecified previous result. Variable time.
modularInverse :: Integer -> Integer -> Either Error Integer
modularInverse value modulus
  | abs modulus <= 1 = Left (InvalidModulus modulus)
  | otherwise =
      let (divisor, coefficient) = euclid (abs modulus) (value `mod` abs modulus) 0 1
       in if divisor == 1 then Right (coefficient `mod` abs modulus) else Left (NoModularInverse value modulus)
  where
    euclid a 0 x _ = (a, x)
    euclid a b x y = let (q, r) = a `quotRem` b; next = x - q * y in next `seq` euclid b r y next

-- | Exact modular power using repeated squaring, with negative exponents
-- interpreted through 'modularInverse'. Zero modulus returns 'InvalidModulus';
-- a missing inverse returns 'NoModularInverse'. Negative moduli use their
-- absolute magnitude. Exponent zero returns 1, including modulus +/-1, as in
-- the native API; nonzero powers modulo +/-1 return 0. Negative exponents
-- with those moduli are rejected. Variable time; no constant-time guarantee.
modularPower :: Integer -> Integer -> Integer -> Either Error Integer
modularPower value power modulus
  | modulus == 0 = Left (InvalidModulus modulus)
  | power == 0 = Right 1
  | power < 0 = do
      inverse <- modularInverse value modulus
      pure (square inverse (negate power) 1)
  | otherwise = Right (square (value `mod` magnitude) power 1)
  where
    magnitude = abs modulus
    square _ 0 result = result
    square factor remaining result =
      let productValue = if odd remaining then (result * factor) `mod` magnitude else result
          nextFactor = (factor * factor) `mod` magnitude
       in productValue `seq` nextFactor `seq` square nextFactor (remaining `quot` 2) productValue

-- FUNCTIONS ------------------------------------------------------------------

asciiSpace :: Char -> Bool
asciiSpace c = c `elem` [' ', '\t', '\n', '\r', '\f', '\v']

signed :: Text -> (Bool, Text)
signed text =
  let prefix = T.dropWhile asciiSpace (T.takeWhile (/= '\0') text)
   in case T.stripPrefix "-" prefix of Just rest -> (True, rest); Nothing -> (False, prefix)

parseDigits :: Int -> Bool -> Text -> Either Error Integer
parseDigits radix negative text
  | T.null digits = Left (InvalidIntegerText "missing digits")
  | otherwise = (if negative then negate else id) <$> T.foldl' consume (Right 0) digits
  where
    digits = T.filter (not . asciiSpace) text
    consume failure@(Left _) _ = failure
    consume (Right accumulated) c = do
      digit <- case () of
        _ | isDigit c -> Right (ord c - ord '0')
        _ | isAsciiUpper c -> Right (ord c - ord 'A' + 10)
        _ | isAsciiLower c -> Right (ord c - ord 'a' + if radix <= 36 then 10 else 36)
        _ -> Left (InvalidIntegerText "invalid digit")
      if digit >= radix then Left (InvalidIntegerText "digit exceeds radix") else let next = accumulated * toInteger radix + toInteger digit in next `seq` Right next

digitCharacter :: Int -> Int -> Char
digitCharacter radix digit
  | digit < 10 = chr (ord '0' + digit)
  | radix <= 36 = chr (ord 'a' + digit - 10)
  | digit < 36 = chr (ord 'A' + digit - 10)
  | otherwise = chr (ord 'a' + digit - 36)
