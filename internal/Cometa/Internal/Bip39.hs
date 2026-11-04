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

-- | Operation-scoped BIP39 marshaling. Native conversion has no acquired owner.
-- Scratch entropy is wiped on success, failure and cancellation after foreign
-- unwind. Validation does not copy entropy into a hidden host ByteString.
-- Native stack intermediates and ordinary host secret values are not erased.
module Cometa.Internal.Bip39 (fromEntropy, validate, exportEntropy) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.FFI.Bip39 as Native
import Cometa.Internal.FFI.Native (NativeCode, cErrorMessage, success)
import Cometa.Internal.Failure (NativeFailure (..))
import Cometa.Internal.Ownership (copyStaticText)
import Control.Exception (finally)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, pokeArray, withArray)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- DEFINITIONS ----------------------------------------------------------------

-- | Borrow validated entropy and copy static words before leaving the scope.
fromEntropy :: ByteString -> IO (Either NativeFailure [Text])
fromEntropy entropy = ByteString.useAsCString entropy $ \input ->
  allocaArray 24 $ \output -> alloca $ \count -> do
    pokeArray output (replicate 24 nullPtr)
    poke count 0
    status <- Native.cFromEntropy (castPtr input) (fromIntegral size) output count
    actual <- peek count
    if status /= success
      then Left <$> nativeFailure "bip39.fromEntropy" status
      else
        if actual /= fromIntegral (size * 3 `div` 4)
          then pure (Left (NativeContractFailure "bip39.fromEntropy"))
          else do
            pointers <- peekArray (fromIntegral actual) output
            if nullPtr `elem` pointers
              then pure (Left (NativeContractFailure "bip39.fromEntropy"))
              else do
                bytes <- mapM ByteString.packCString pointers
                pure $ case traverse Text.decodeUtf8' bytes of
                  Left _ -> Left (NativeContractFailure "bip39.fromEntropy")
                  Right words' -> Right words'
  where
    size = ByteString.length entropy

-- | Validate without exporting a host copy of the secret entropy.
validate :: [Text] -> IO (Either NativeFailure ())
validate words' = decodeEntropy words' (\_ _ -> pure ())

-- | Copy entropy only when explicitly requested by the public caller.
exportEntropy :: [Text] -> IO (Either NativeFailure ByteString)
exportEntropy words' = decodeEntropy words' $ \output size -> ByteString.packCStringLen (castPtr output, size)

decodeEntropy :: [Text] -> (Ptr Word8 -> Int -> IO a) -> IO (Either NativeFailure a)
decodeEntropy words' consume =
  withWords words' $ \inputs -> allocaBytes 32 $ \output ->
    decodeOutput words' inputs output consume `finally` Native.cClear output 32

decodeOutput :: [Text] -> Ptr CString -> Ptr Word8 -> (Ptr Word8 -> Int -> IO a) -> IO (Either NativeFailure a)
decodeOutput words' inputs output consume = alloca $ \size -> do
  poke size 0
  status <- Native.cToEntropy inputs (fromIntegral (length words')) output 32 size
  actual <- peek size
  if status == success
    then
      if actual == fromIntegral (length words' * 4 `div` 3)
        then Right <$> consume output (fromIntegral actual)
        else pure (Left (NativeContractFailure "bip39.toEntropy"))
    else Left <$> nativeFailure "bip39.toEntropy" status

-- Every temporary UTF-8 input is borrowed only within its nested scope.
withWords :: [Text] -> (Ptr CString -> IO a) -> IO a
withWords words' action = go words' []
  where
    go [] pointers = withArray (reverse pointers) action
    go (word : rest) pointers = ByteString.useAsCString (Text.encodeUtf8 word) $ \pointer -> go rest (pointer : pointers)

nativeFailure :: Text -> NativeCode -> IO NativeFailure
nativeFailure operation status = do
  diagnostic <- cErrorMessage status >>= copyStaticText
  pure (NativeFailure operation (fromIntegral status) diagnostic)
