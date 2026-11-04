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
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK hide #-}

-- | One scoped native owner and one rooted wrapper per handler. The state lock
-- serializes all native access; tryTakeMVar makes overlap and reentry fail fast.
-- Scope cleanup waits for native/callback workers before freeing the wrapper.
module Cometa.Internal.KeyHandler
  ( Handler,
    Failure (..),
    withEntropy,
    withSigningKey,
    withSerialized,
    close,
    serialize,
    name,
    accountPublicKey,
    publicKey,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.Callback as Callback
import qualified Cometa.Internal.FFI.KeyHandler as Native
import qualified Cometa.Internal.FFI.Native as Status
import qualified Cometa.Internal.FFI.PasswordCrypto as Buffer
import qualified Cometa.Internal.Failure as Failure
import Cometa.Internal.Ownership (copyStaticText)
import qualified Cometa.Internal.SigningKey as Signing
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, tryTakeMVar)
import Control.Exception (Exception, SomeException, bracket, catch, finally, getMaskingState, mask, mask_, throwIO, uninterruptibleMask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Data.Word (Word32, Word8)
import Foreign.C.Types (CSize)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (FunPtr, Ptr, castPtr, freeHaskellFunPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

data Handler = Handler (MVar (Maybe (Ptr Native.NativeHandler))) Callback.CallbackControl

data Failure = Closed | Busy | PasswordLength !Int | InvalidStorage | SourceClosed | NativeFailure !Failure.NativeFailure deriving (Eq, Show)

newtype InvalidPassword = InvalidPassword Int deriving (Show)

instance Exception InvalidPassword

type Acquisition = Ptr (Ptr Native.NativeHandler) -> IO (Either Failure ())

-- DEFINITIONS ----------------------------------------------------------------

-- | Inputs are completely marshaled before acquiring source locks. Native
-- constructors encrypt immediately and do not invoke the password callback.
withEntropy :: ByteString -> ByteString -> IO ByteString -> (Handler -> IO value) -> IO (Either Failure value)
withEntropy entropy password callback action =
  withValidPassword password $
    withAcquired callback acquire action
  where
    acquire fun output = withBytes entropy $ \bytes size ->
      withBytes password $ \pass passSize ->
        checkStatus "keyHandler.withEntropy" (Native.cNew bytes size pass passSize fun output)

withSigningKey :: Signing.Key -> ByteString -> IO ByteString -> (Handler -> IO value) -> IO (Either Failure value)
withSigningKey source password callback action =
  withValidPassword password $
    withAcquired callback acquire action
  where
    acquire fun output = withBytes password $ \pass passSize -> do
      result <- Signing.withKey source $ \key -> Right <$> Native.cEdNew key pass passSize fun output
      case result of
        Left Signing.Closed -> pure (Left SourceClosed)
        Left _ -> pure (contractFailure "keyHandler.withSigningKey")
        Right code -> status "keyHandler.withSigningKey" code

-- | Validate exact framing and canonical inner lengths before native allocation.
-- Native validates checksum. This format is binary, and outer metadata has CRC
-- protection only; deserialization does not authenticate the encrypted payload.
withSerialized :: ByteString -> IO ByteString -> (Bool -> Handler -> IO value) -> IO (Either Failure value)
withSerialized bytes callback action = case storageKind bytes of
  Nothing -> pure (Left InvalidStorage)
  Just bip32 -> withAcquired callback acquire (action bip32)
  where
    acquire fun output = withBytes bytes $ \pointer size ->
      checkStatus "keyHandler.withSerialized" (Native.cDeserialize pointer size fun output)

storageKind :: ByteString -> Maybe Bool
storageKind bytes = case ByteString.unpack (ByteString.take 10 bytes) of
  [10, 10, 10, 10, 1, kind, a, b, c, d]
    | kind <= 1 && size `elem` allowed && toInteger (ByteString.length bytes) == size + 14 -> Just (kind == 1)
    where
      size = foldl (\n x -> n * 256 + fromIntegral x) 0 [a, b, c, d] :: Integer
      allowed = if kind == 1 then [76, 80, 84, 88, 92] else [92, 124]
  _ -> Nothing

withValidPassword :: ByteString -> IO (Either Failure value) -> IO (Either Failure value)
withValidPassword password action
  | size < 1 || size > 128 = pure (Left (PasswordLength size))
  | otherwise = action
  where
    size = ByteString.length password

-- | The wrapper captures this handler's control; native has no context argument.
-- No callback registration or supplied password is kept beyond scope exit.
withAcquired :: IO ByteString -> (ForeignFun -> Acquisition) -> (Handler -> IO value) -> IO (Either Failure value)
withAcquired callback acquire action = mask $ \restore -> do
  control <- Callback.newCallbackControl
  state <- newMVar Nothing
  let handler = Handler state control
  bracket (Native.wrapPassphrase (passphraseCallback control callback)) freeHaskellFunPtr $ \fun ->
    alloca $ \slot -> bracket (poke slot nullPtr >> pure slot) (cleanup handler) $ \output -> do
      result <- restore (acquire fun output)
      case result of
        Left failure -> pure (Left failure)
        Right () -> do
          pointer <- peek output
          if pointer == nullPtr
            then pure (contractFailure "keyHandler.acquire")
            else do
              _ <- takeMVar state
              putMVar state (Just pointer)
              poke output nullPtr
              Right <$> restore (action handler)

type ForeignFun = FunPtr Native.PassphraseCallback

cleanup :: Handler -> Ptr (Ptr Native.NativeHandler) -> IO ()
cleanup (Handler state _) output = uninterruptibleMask_ $ do
  current <- takeMVar state
  case current of
    Nothing -> Native.cUnref output
    Just pointer -> release pointer `finally` poke output nullPtr
  poke output nullPtr
  putMVar state Nothing

close :: Handler -> IO (Either Failure ())
close (Handler state _) = mask_ $ do
  current <- tryTakeMVar state
  case current of
    Nothing -> pure (Left Busy)
    Just pointer -> (maybe (pure ()) release pointer >> pure (Right ())) `finally` putMVar state Nothing

release :: Ptr Native.NativeHandler -> IO ()
release pointer = alloca $ \slot -> poke slot pointer >> Native.cUnref slot

-- | Acquisition does not call back. Operations may, so cancellation is directed
-- to the user worker and both workers join before the state lock is returned.
withOperation :: Handler -> (Ptr Native.NativeHandler -> IO (Either Failure value)) -> IO (Either Failure value)
withOperation (Handler state control) action = do
  callerMasking <- getMaskingState
  mask $ \restore -> do
    current <- tryTakeMVar state
    case current of
      Nothing -> pure (Left Busy)
      Just Nothing -> putMVar state Nothing >> pure (Left Closed)
      Just (Just pointer) ->
        ( do
            Callback.beginCallbackOperation control callerMasking
            finished <- newEmptyMVar
            let nativeOperation = do
                  result <- action pointer
                  (Callback.rethrowCallbackException control >> pure result)
                    `catch` invalidPassword
                invalidPassword (InvalidPassword size) = pure (Left (PasswordLength size))
            _ <- forkFinally nativeOperation (putMVar finished)
            outcome <- restore (readMVar finished) `catch` cancelAndJoin control finished
            either throwIO pure outcome
        )
          `finally` (Callback.finishCallbackOperation control >> putMVar state (Just pointer))

cancelAndJoin :: Callback.CallbackControl -> MVar (Either SomeException value) -> SomeException -> IO result
cancelAndJoin control finished cause = uninterruptibleMask_ $ do
  Callback.cancelCallbackOperation control cause
  _ <- readMVar finished
  throwIO cause

-- | Force bytes, length and copying inside the protected user worker. The ABI
-- callback catches every exception and returns -1; it never unwinds through C.
passphraseCallback :: Callback.CallbackControl -> IO ByteString -> Native.PassphraseCallback
passphraseCallback control callback output capacity =
  mask_ $
    Callback.runCallbackWorker
      control
      ( do
          bytes <- callback
          let size = ByteString.length bytes
          if size < 1 || size > 128 || toInteger size > toInteger capacity
            then throwIO (InvalidPassword size)
            else ByteString.useAsCString bytes $ \source -> copyBytes output (castPtr source) size >> pure (fromIntegral size)
      )
      `catch` \(cause :: SomeException) -> uninterruptibleMask_ (Callback.rememberCallbackException control cause >> pure (-1))

accountPublicKey :: Handler -> Word32 -> Word32 -> Word32 -> IO (Either Failure ByteString)
accountPublicKey handler purpose coin account = withOperation handler $ \pointer ->
  copyOutput "keyHandler.accountPublicKey" 64 (Native.cAccount pointer purpose coin account)

publicKey :: Handler -> IO (Either Failure ByteString)
publicKey handler = withOperation handler $ \pointer -> copyOutput "keyHandler.publicKey" 32 (Native.cPublic pointer)

name :: Handler -> IO (Either Failure Text)
name handler = withOperation handler $ \pointer -> Right <$> (Native.cName pointer >>= copyStaticText)

serialize :: Handler -> IO (Either Failure ByteString)
serialize handler = withOperation handler $ \pointer -> alloca $ \slot ->
  bracket (poke slot nullPtr >> pure slot) Buffer.cRelease $ \output -> do
    result <- checkStatus "keyHandler.serialize" (Native.cSerialize pointer output)
    case result of
      Left failure -> pure (Left failure)
      Right () -> do
        buffer <- peek output
        if buffer == nullPtr
          then pure (contractFailure "keyHandler.serialize")
          else do
            size <- Buffer.cSize buffer
            bytes <- Buffer.cData buffer
            Right <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)

copyOutput :: Text -> Int -> (Ptr Word8 -> IO Status.NativeCode) -> IO (Either Failure ByteString)
copyOutput operation size call = allocaBytes size $ \output -> do
  result <- checkStatus operation (call output)
  case result of
    Left failure -> pure (Left failure)
    Right () -> Right <$> ByteString.packCStringLen (castPtr output, size)

checkStatus :: Text -> IO Status.NativeCode -> IO (Either Failure ())
checkStatus operation call = call >>= status operation

status :: Text -> Status.NativeCode -> IO (Either Failure ())
status operation code
  | code == Status.success = pure (Right ())
  | otherwise = do
      message <- Status.cErrorMessage code >>= copyStaticText
      pure (Left (NativeFailure (Failure.NativeFailure operation (toInteger code) message)))

contractFailure :: Text -> Either Failure value
contractFailure = Left . NativeFailure . Failure.NativeContractFailure

withBytes :: ByteString -> (Ptr Word8 -> CSize -> IO value) -> IO value
withBytes bytes action = ByteString.useAsCStringLen bytes $ \(pointer, size) -> action (castPtr pointer) (fromIntegral size)
