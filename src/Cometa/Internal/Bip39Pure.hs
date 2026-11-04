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
{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Narrow purity exception for the audited pinned BIP39 conversion path.
-- No owner, callback, logger, RNG, allocator configuration or mutable error
-- state is reached. See docs/development/BIP39_PURITY.md for the build audit
-- and re-audit requirements. These concrete monomorphic NOINLINE boundaries
-- follow base's unsafePerformIO optimizer safeguards; never generalize them to
-- an arbitrary IO runner. Re-evaluation or sharing is semantically harmless.
-- Safe foreign calls unwind before finally wipes scratch on cancellation.
-- Results (including errors) are forced before leaving the private IO action.
module Cometa.Internal.Bip39Pure (Mnemonic, fromEntropy, fromText, fromWords, wordCount, exportText, exportEntropy) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.Bip39 as Internal
import Cometa.Internal.Error (fromNativeFailure)
import Cometa.Internal.Failure (NativeFailure (..))
import Control.Exception (evaluate)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isAsciiLower)
import Data.Text (Text)
import qualified Data.Text as Text
import System.IO.Unsafe (unsafePerformIO)

-- TYPES ----------------------------------------------------------------------

-- | A checksum-validated sequence of 12, 15, 18, 21 or 24 lowercase English
-- BIP39 words. Constructors are hidden; secret export is explicit.
newtype Mnemonic = Mnemonic [Text]

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate the bound before entering the audited conversion; force owned words.
{-# NOINLINE fromEntropy #-}
fromEntropy :: ByteString -> Either Error Mnemonic
fromEntropy entropy
  | size `notElem` [16, 20, 24, 28, 32] = Left (InvalidBip39EntropyLength size)
  | otherwise = unsafePerformIO $ do
      result <- fmap (either (Left . fromNativeFailure) (Right . Mnemonic)) (Internal.fromEntropy entropy)
      evaluate (forceMnemonic result)
      pure result
  where
    size = ByteString.length entropy

-- | Unicode splitting is pure and delegates to the concrete word boundary.
fromText :: Text -> Either Error Mnemonic
fromText = fromWords . Text.words

-- | Preserve domain/native errors; force the retained input words before return.
{-# NOINLINE fromWords #-}
fromWords :: [Text] -> Either Error Mnemonic
fromWords words' = case validateWords words' of
  Left err -> Left err
  Right () -> unsafePerformIO $ do
    result <- fmap (either (Left . mnemonicError) (const (Right (Mnemonic words')))) (Internal.validate words')
    evaluate (forceMnemonic result)
    pure result

-- | Inspect the materialized list.
wordCount :: Mnemonic -> Int
wordCount (Mnemonic words') = length words'

-- | Explicitly materialize a caller-requested secret phrase.
exportText :: Mnemonic -> Text
exportText (Mnemonic words') = Text.unwords words'

-- | Preserve all native/contract errors; force the owned copy before return.
{-# NOINLINE exportEntropy #-}
exportEntropy :: Mnemonic -> Either Error ByteString
exportEntropy (Mnemonic words') = unsafePerformIO $ do
  result <- fmap (either (Left . fromNativeFailure) Right) (Internal.exportEntropy words')
  evaluate (case result of Left err -> forceError err; Right bytes -> ByteString.length bytes `seq` ())
  pure result

validateWords :: [Text] -> Either Error ()
validateWords words'
  | count `notElem` [12, 15, 18, 21, 24] = Left (InvalidBip39WordCount count)
  | otherwise = mapM_ validate (zip [1 ..] words')
  where
    count = length words'
    validate (position, word)
      | Text.null word || not (Text.all isAsciiLower word) = Left (InvalidBip39Word position)
      | otherwise = Right ()

mnemonicError :: NativeFailure -> Error
mnemonicError failure = case failure of
  NativeFailure _ status _
    | Code.fromNumber status == Code.InvalidChecksum -> InvalidBip39Checksum
    | Code.fromNumber status == Code.InvalidArgument -> UnknownBip39Word
  _ -> fromNativeFailure failure

-- Force the actual word list, without constructing another secret phrase.
-- Strict Text/ByteString values own their contents; forcing their lengths and
-- every list cell leaves no deferred decoding or borrowed foreign reads.
forceMnemonic :: Either Error Mnemonic -> ()
forceMnemonic (Left err) = forceError err
forceMnemonic (Right (Mnemonic words')) = forceWords words'
  where
    forceWords [] = ()
    forceWords (word : rest) = Text.length word `seq` forceWords rest

forceError :: Error -> ()
forceError (NativeError operation code diagnostic) =
  Text.length operation `seq` Code.toNumber code `seq` Text.length diagnostic `seq` ()
forceError (NativeContractViolation operation) = Text.length operation `seq` ()
-- Remaining constructors are nullary or contain strict scalar fields.
forceError err = err `seq` ()
