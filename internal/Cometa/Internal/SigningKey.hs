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

-- | Deterministic secret-key lifetime. One lock protects the closed state and
-- spans every native use, including copying borrowed data. No public callback
-- runs under that lock. Closing waits for existing operations, then wipes and
-- releases the native allocation; escaped handles retain only the closed state.
module Cometa.Internal.SigningKey
  ( Key,
    Failure (..),
    withNormalKey,
    withExtendedKey,
    withNormalKeyHex,
    withExtendedKeyHex,
    withClone,
    close,
    publicKeyBytes,
    signBytes,
    exportBytes,
    byteLength,
    withKey,
    withAcquiredKey,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.FFI.Native as Status
import qualified Cometa.Internal.FFI.SigningKey as Native
import qualified Cometa.Internal.Failure as Failure
import Cometa.Internal.Ownership (copyStaticText)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (bracket, evaluate, finally, mask, uninterruptibleMask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import Foreign.C.Types (CSize)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | No printable or equality instance: this contains a secret ownership state.
newtype Key = Key (MVar (Maybe (Ptr Native.NativeKey)))

-- | Sanitized failures. Lengths are expected then actual; no input is retained.
data Failure
  = Closed
  | InvalidLength !Int !Int
  | InvalidHex
  | NativeFailure !Failure.NativeFailure
  deriving (Eq, Show)

type Acquisition = Ptr (Ptr Native.NativeKey) -> IO (Either Failure ())

type Import = Ptr Word8 -> CSize -> Ptr (Ptr Native.NativeKey) -> IO Status.NativeCode

-- DEFINITIONS ----------------------------------------------------------------

-- | Import a normal 32-byte seed and close the key on every callback exit.
withNormalKey :: ByteString -> (Key -> IO value) -> IO (Either Failure value)
withNormalKey = withBytesKey "ed25519.withNormalKey" 32 Native.cFromNormalBytes

-- | Import an expanded 64-byte scalar/IV key. Length is checked, not scalar validity.
withExtendedKey :: ByteString -> (Key -> IO value) -> IO (Either Failure value)
withExtendedKey = withBytesKey "ed25519.withExtendedKey" 64 Native.cFromExtendedBytes

-- | Import normal seed ASCII hex, rejecting malformed text before native import.
withNormalKeyHex :: Text -> (Key -> IO value) -> IO (Either Failure value)
withNormalKeyHex = withHexKey "ed25519.withNormalKeyHex" 32 Native.cFromNormalHex

-- | Import expanded scalar/IV ASCII hex; input and UTF-8 copies have host lifetimes.
withExtendedKeyHex :: Text -> (Key -> IO value) -> IO (Either Failure value)
withExtendedKeyHex = withHexKey "ed25519.withExtendedKeyHex" 64 Native.cFromExtendedHex

-- | Clone while holding the source lock, then scope the independent key outside
-- that lock. Closing either key never invalidates the other one's native storage.
withClone :: Key -> (Key -> IO value) -> IO (Either Failure value)
withClone source = withAcquiredKey operation $ \output ->
  withKey source $ \pointer -> checkStatus operation (Native.cClone pointer output)
  where
    operation = "ed25519.withClone"

-- | Wait for native operations, invalidate the local handle and release once.
-- Only trusted finite native work holds the lock; no application callback may do so.
close :: Key -> IO ()
close (Key state) = uninterruptibleMask_ $ modifyMVar_ state $ \current -> do
  maybe (pure ()) releasePointer current
  pure Nothing

-- | Derive and copy public bytes while holding the key alive.
publicKeyBytes :: Key -> IO (Either Failure ByteString)
publicKeyBytes key = withKey key $ \pointer ->
  copyOutput "ed25519.publicKey" 32 (Native.cPublicKey pointer)

-- | Force and borrow the message before locking: evaluating a caller's thunk
-- must never prevent concurrent close from acquiring this non-reentrant lock.
signBytes :: Key -> ByteString -> IO (Either Failure ByteString)
signBytes key message = withBytes message $ \bytes size ->
  withKey key $ \pointer -> copyOutput "ed25519.sign" 64 (Native.cSign pointer bytes size)

-- | Copy secret storage directly into a host ByteString, without an intermediate
-- native export buffer. The copy has no controlled erasure or lifetime guarantee.
exportBytes :: Key -> IO (Either Failure ByteString)
exportBytes key = withKey key $ \pointer -> do
  size <- Native.cSize pointer
  bytes <- Native.cData pointer
  if bytes == nullPtr || (size /= 32 && size /= 64)
    then pure (contractFailure "ed25519.exportBytes")
    else Right <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)

-- | Read only the fixed-size scalar metadata, without copying any secret bytes.
byteLength :: Key -> IO (Either Failure Int)
byteLength key = withKey key $ \pointer -> do
  size <- Native.cSize pointer
  pure $
    if size == 32 || size == 64
      then Right (fromIntegral size)
      else contractFailure "ed25519.byteLength"

-- | Trusted internal operation/test seam. Holds the key lock through the entire
-- action; reject closed handles before exposing any pointer. The action must not
-- escape the pointer, run application callbacks or force application-owned input.
withKey :: Key -> (Ptr Native.NativeKey -> IO (Either Failure value)) -> IO (Either Failure value)
withKey (Key state) action = withMVar state $ \current ->
  maybe (pure (Left Closed)) action current

-- | Validate all application input before construction. Native import copies it.
withBytesKey :: Text -> Int -> Import -> ByteString -> (Key -> IO value) -> IO (Either Failure value)
withBytesKey operation expected importKey bytes action
  | actual /= expected = pure (Left (InvalidLength expected actual))
  | otherwise = withAcquiredKey operation acquire action
  where
    actual = ByteString.length bytes
    acquire output = withBytes bytes $ \pointer size ->
      checkStatus operation (importKey pointer size output)

-- | Validate ASCII hex without decoding it into an additional host secret byte
-- array. UTF-8 marshaling still creates host storage which Haskell does not erase.
withHexKey :: Text -> Int -> Import -> Text -> (Key -> IO value) -> IO (Either Failure value)
withHexKey operation expected importKey text action
  | Text.null text || odd digits || not (Text.all isHex text) = pure (Left InvalidHex)
  | actual /= expected = pure (Left (InvalidLength expected actual))
  | otherwise = withAcquiredKey operation acquire action
  where
    digits = Text.length text
    actual = digits `div` 2
    acquire output = withBytes (Text.encodeUtf8 text) $ \pointer size ->
      checkStatus operation (importKey pointer size output)
    isHex character =
      isDigit character
        || (character >= 'a' && character <= 'f')
        || (character >= 'A' && character <= 'F')

-- | Install ownership-aware cleanup before unmasked acquisition and retain it
-- through the callback. Publication is masked; the finalizer handles either
-- ownership state even if an exception arrives between publication and slot clear.
withAcquiredKey :: Text -> Acquisition -> (Key -> IO value) -> IO (Either Failure value)
withAcquiredKey operation acquire action = mask $ \restore -> do
  state <- newMVar Nothing
  key <- evaluate (Key state)
  alloca $ \slot ->
    bracket (poke slot nullPtr >> pure slot) (closeAcquiredKey key) $ \output -> do
      result <- restore (acquire output)
      case result of
        Left failure -> pure (Left failure)
        Right () -> do
          pointer <- peek output
          if pointer == nullPtr
            then pure (contractFailure operation)
            else do
              modifyMVar_ state (const (pure (Just pointer)))
              poke output nullPtr
              Right <$> restore (action key)

-- | Consume exactly one reference across publication. A populated state is the
-- authority even while the output slot temporarily aliases it. Otherwise the
-- slot owns any partial acquisition result. Early 'close' leaves both empty.
closeAcquiredKey :: Key -> Ptr (Ptr Native.NativeKey) -> IO ()
closeAcquiredKey (Key state) slot = uninterruptibleMask_ $ modifyMVar_ state $ \current -> do
  case current of
    Nothing -> releaseSlot slot
    Just pointer -> releasePointer pointer `finally` poke slot nullPtr
  pure Nothing

-- | Consume one local obligation, irrespective of whether native unref nulls it.
releaseSlot :: Ptr (Ptr Native.NativeKey) -> IO ()
releaseSlot slot = Native.cUnref slot `finally` poke slot nullPtr

-- | Release a state-owned reference through the typed pointer-to-pointer API.
releasePointer :: Ptr Native.NativeKey -> IO ()
releasePointer pointer = alloca $ \slot -> poke slot pointer >> releaseSlot slot

-- | Public/signature outputs contain no secret material and have fixed length.
copyOutput :: Text -> Int -> (Ptr Word8 -> IO Status.NativeCode) -> IO (Either Failure ByteString)
copyOutput operation size call = allocaBytes size $ \output -> do
  result <- checkStatus operation (call output)
  case result of
    Left failure -> pure (Left failure)
    Right () -> Right <$> ByteString.packCStringLen (castPtr output, size)

-- | Copy static native diagnostics; operation labels never contain key input.
checkStatus :: Text -> IO Status.NativeCode -> IO (Either Failure ())
checkStatus operation action = do
  code <- action
  if code == Status.success
    then pure (Right ())
    else do
      message <- Status.cErrorMessage code >>= copyStaticText
      pure (Left (NativeFailure (Failure.NativeFailure operation (toInteger code) message)))

contractFailure :: Text -> Either Failure value
contractFailure = Left . NativeFailure . Failure.NativeContractFailure

-- | Keep marshaled bytes alive only through the chosen native action.
withBytes :: ByteString -> (Ptr Word8 -> CSize -> IO value) -> IO value
withBytes bytes action = ByteString.useAsCStringLen bytes $ \(pointer, size) -> action (castPtr pointer) (fromIntegral size)
