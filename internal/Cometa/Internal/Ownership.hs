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

-- | Scoped native acquisition. Initialize the output slot before calling C,
-- release even partial failure results, and copy data before releasing its owner.
-- 'bracket' installs cleanup before acquisition and restores the caller's masking
-- state around the acquisition and action.
-- A safe, non-interruptible FFI call finishes writing its output slot before a
-- pending asynchronous exception unwinds the scope and releases that output.
module Cometa.Internal.Ownership
  ( withOwnedOutput,
    copyHashResult,
    copyStaticText,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.FFI.Native as Native
import Cometa.Internal.Failure (NativeFailure (..))
import Control.Exception (bracket, finally)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import Foreign.C.String (CString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- DIAGNOSTICS ----------------------------------------------------------------

-- | Copy a static UTF-8 diagnostic. Native diagnostics are expected to be UTF-8;
-- invalid sequences are replaced rather than raising an unrelated exception.
copyStaticText :: CString -> IO Text
copyStaticText pointer =
  if pointer == nullPtr
    then pure ""
    else Text.decodeUtf8With Text.lenientDecode <$> ByteString.packCString pointer

-- OWNED OUTPUTS --------------------------------------------------------------

-- | Scope one owned output reference, including a partial result written before
-- failure or an exception. Acquisition runs with the caller's masking state after
-- cleanup is installed. Safe, non-interruptible FFI must finish before unwinding;
-- interruptible foreign calls require a separate lifetime protocol.
--
-- The acquisition must leave either null or one locally owned reference in its
-- slot on every exit. The action borrows that reference and must not release,
-- transfer, or replace it. Its result must not contain a borrowed native view.
-- The bounded destructor must not throw or block interruptibly. Clearing the
-- slot records release even when another native owner keeps the object alive.
withOwnedOutput ::
  Text ->
  (Ptr (Ptr native) -> IO ()) ->
  (Ptr (Ptr native) -> IO Native.NativeCode) ->
  (Ptr native -> IO (Either NativeFailure value)) ->
  IO (Either NativeFailure value)
withOwnedOutput operation release acquire action =
  alloca $ \slot ->
    bracket (poke slot nullPtr >> pure slot) cleanup $ \output -> do
      code <- acquire output
      if code /= Native.success
        then do
          message <- Native.cErrorMessage code >>= copyStaticText
          pure (Left (NativeFailure operation (toInteger code) message))
        else do
          pointer <- peek output
          if pointer == nullPtr
            then pure (Left (NativeContractFailure operation))
            else action pointer
  where
    cleanup slot = do
      pointer <- peek slot
      if pointer == nullPtr
        then pure ()
        else release slot `finally` poke slot nullPtr

-- HASH SNAPSHOTS -------------------------------------------------------------

-- | Copy borrowed hash storage before releasing its owned output reference.
-- A null pointer, zero length, or length beyond Haskell's 'Int' range is a native
-- contract failure. No borrowed storage escapes in the returned bytes.
copyHashResult :: Text -> (Ptr (Ptr Native.NativeHash) -> IO Native.NativeCode) -> IO (Either NativeFailure ByteString)
copyHashResult operation acquire =
  withOwnedOutput operation Native.cUnref acquire $ \hash -> do
    size <- Native.cSize hash
    bytes <- Native.cData hash
    if bytes == nullPtr || size == 0 || toInteger size > toInteger (maxBound :: Int)
      then pure (Left (NativeContractFailure operation))
      else Right <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)
