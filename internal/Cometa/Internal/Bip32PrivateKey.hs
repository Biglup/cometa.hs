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
module Cometa.Internal.Bip32PrivateKey
  ( Key,
    Failure (..),
    withBytesKey,
    withHexKey,
    withDerived,
    withEntropy,
    withSigningKey,
    withClone,
    close,
    publicKeyBytes,
    exportBytes,
    byteLength,
    withKey,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.FFI.Bip32 as Native
import qualified Cometa.Internal.FFI.Native as Status
import qualified Cometa.Internal.Failure as Failure
import Cometa.Internal.Ownership (copyStaticText)
import qualified Cometa.Internal.SigningKey as Signing
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (bracket, evaluate, finally, mask, uninterruptibleMask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word32, Word8)
import Foreign.C.Types (CSize)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (withArrayLen)
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

-- | Import exactly 96 bytes; only the encoded length is checked.
withBytesKey :: ByteString -> (Key -> IO value) -> IO (Either Failure value)
withBytesKey = importBytes "bip32.withKey" 96 Native.cFromBytes

-- | Import validated ASCII hex without decoding an extra host secret buffer.
withHexKey :: Text -> (Key -> IO value) -> IO (Either Failure value)
withHexKey = importHex "bip32.withKeyHex" 96 Native.cFromHex

-- | Derive into independent ownership. Evaluate the complete caller-owned path
-- before taking the source lock; the continuation runs outside that lock.
withDerived :: Key -> [Word32] -> (Key -> IO value) -> IO (Either Failure value)
withDerived source [] = withClone source
withDerived source path = \action -> withArrayLen path $ \size indices ->
  withAcquiredKey
    "bip32.withDerived"
    ( \output ->
        withKey source $ \pointer ->
          checkStatus
            "bip32.withDerived"
            (Native.cDerive pointer indices (fromIntegral size) output)
    )
    action

-- | Root derivation borrows password and entropy through the complete call.
-- Length policy is imposed by the public layer before this internal seam.
withEntropy :: ByteString -> ByteString -> (Key -> IO value) -> IO (Either Failure value)
withEntropy password entropy action = withBytes password $ \passwordBytes passwordSize ->
  withBytes entropy $ \entropyBytes entropySize ->
    withAcquiredKey "bip32.withEntropy" (acquire passwordBytes passwordSize entropyBytes entropySize) action
  where
    acquire passwordBytes passwordSize entropyBytes entropySize output =
      checkStatus "bip32.withEntropy" (Native.cFromEntropy passwordBytes passwordSize entropyBytes entropySize output)

-- | Transfer a fresh native Ed25519 key directly into its independent scope.
-- No intermediate Haskell secret bytes are created. Neither callback holds a lock.
withSigningKey :: Key -> (Signing.Key -> IO value) -> IO (Either Failure value)
withSigningKey source action = do
  result <-
    Signing.withAcquiredKey
      "bip32.withSigningKey"
      ( \output -> do
          converted <- withKey source $ \pointer -> checkStatus "bip32.withSigningKey" (Native.cToSigningKey pointer output)
          pure (either (Left . toSigningFailure) Right converted)
      )
      action
  pure (either (Left . fromSigningFailure) Right result)
  where
    toSigningFailure Closed = Signing.Closed
    toSigningFailure (InvalidLength expected actual) = Signing.InvalidLength expected actual
    toSigningFailure InvalidHex = Signing.InvalidHex
    toSigningFailure (NativeFailure failure) = Signing.NativeFailure failure
    fromSigningFailure Signing.Closed = Closed
    fromSigningFailure (Signing.InvalidLength expected actual) = InvalidLength expected actual
    fromSigningFailure Signing.InvalidHex = InvalidHex
    fromSigningFailure (Signing.NativeFailure failure) = NativeFailure failure

-- | Clone while holding the source lock, then scope the independent key outside
-- that lock. Closing either key never invalidates the other one's native storage.
withClone :: Key -> (Key -> IO value) -> IO (Either Failure value)
withClone source = withAcquiredKey operation $ \output ->
  withKey source $ \pointer -> checkStatus operation (Native.cClone pointer output)
  where
    operation = "bip32.withClone"

-- | Wait for native operations, invalidate the local handle and release once.
-- Only trusted finite native work holds the lock; no application callback may do so.
close :: Key -> IO ()
close (Key state) = uninterruptibleMask_ $ modifyMVar_ state $ \current -> do
  maybe (pure ()) releasePointer current
  pure Nothing

-- | Derive and copy public bytes while holding the key alive.
publicKeyBytes :: Key -> IO (Either Failure ByteString)
publicKeyBytes key = withKey key $ \pointer ->
  copyOutput "bip32.publicKey" 64 (Native.cPublicKey pointer)

-- | Copy secret storage directly into a host ByteString, without an intermediate
-- native export buffer. The copy has no controlled erasure or lifetime guarantee.
exportBytes :: Key -> IO (Either Failure ByteString)
exportBytes key = withKey key $ \pointer -> do
  size <- Native.cSize pointer
  bytes <- Native.cData pointer
  if bytes == nullPtr || size /= 96
    then pure (contractFailure "bip32.exportBytes")
    else Right <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)

-- | Read only the fixed-size scalar metadata, without copying any secret bytes.
byteLength :: Key -> IO (Either Failure Int)
byteLength key = withKey key $ \pointer -> do
  size <- Native.cSize pointer
  pure $
    if size == 96
      then Right (fromIntegral size)
      else contractFailure "bip32.byteLength"

-- | Trusted internal operation/test seam. Holds the key lock through the entire
-- action; reject closed handles before exposing any pointer. The action must not
-- escape the pointer, run application callbacks or force application-owned input.
withKey :: Key -> (Ptr Native.NativeKey -> IO (Either Failure value)) -> IO (Either Failure value)
withKey (Key state) action = withMVar state $ \current ->
  maybe (pure (Left Closed)) action current

-- | Validate all application input before construction. Native import copies it.
importBytes :: Text -> Int -> Import -> ByteString -> (Key -> IO value) -> IO (Either Failure value)
importBytes operation expected importKey bytes action
  | actual /= expected = pure (Left (InvalidLength expected actual))
  | otherwise = withAcquiredKey operation acquire action
  where
    actual = ByteString.length bytes
    acquire output = withBytes bytes $ \pointer size ->
      checkStatus operation (importKey pointer size output)

-- | Validate ASCII hex without decoding it into an additional host secret byte
-- array. UTF-8 marshaling still creates host storage which Haskell does not erase.
importHex :: Text -> Int -> Import -> Text -> (Key -> IO value) -> IO (Either Failure value)
importHex operation expected importKey text action
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

-- | Public outputs contain no secret material and have fixed length.
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
