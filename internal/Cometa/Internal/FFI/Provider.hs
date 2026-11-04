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
{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Private C adapter. Explicit status values use an unsigned C ABI;
-- the adapter owns layout, native bool conversion and adopted runtime handles.
-- All entry points use safe calls, including reference destruction.
module Cometa.Internal.FFI.Provider
  ( -- * ABI types and callback registration
    NativeProvider,
    ConfirmationCallback,
    wrapConfirmation,

    -- * Native status values
    success,
    failure,

    -- * Provider references and operations
    cNew,
    cRef,
    cRelease,
    cConfirm,
    cError,

    -- * Lifecycle evidence
    cLiveContexts,
    cCompletedCalls,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word64, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Ptr (FunPtr, Ptr)
import Foreign.StablePtr (StablePtr)

-- TYPES ----------------------------------------------------------------------

-- | Opaque native provider. Only the C adapter reads its representation.
data NativeProvider

-- | Synchronous callback ABI. All pointers are borrowed until return. The bridge
-- must contain exceptions and write a 0/1 confirmation plus a bounded diagnostic.
-- Native @bool@ never crosses this boundary.
type ConfirmationCallback state =
  StablePtr state ->
  -- | Transaction ID bytes and their length.
  Ptr Word8 ->
  CSize ->
  -- | Timeout in milliseconds.
  Word64 ->
  -- | Confirmation output and diagnostic buffer, including terminator capacity.
  Ptr CInt ->
  CString ->
  CSize ->
  IO CInt

-- DEFINITIONS ----------------------------------------------------------------

-- | Successful callback status.
success :: CInt
success = 0

-- | Generic callback failure status used after exception containment.
failure :: CInt
failure = 1

-- FOREIGN IMPORTS ------------------------------------------------------------

-- | Allocate a callable trampoline. The native context adopts it only after
-- 'cNew' succeeds; otherwise Haskell must free it along with its stable pointer.
foreign import ccall "wrapper"
  wrapConfirmation :: ConfirmationCallback state -> IO (FunPtr (ConfirmationCallback state))

-- | Construct one owned provider reference. Success adopts both runtime handles;
-- failure leaves both with the caller and leaves the initialized output null.
foreign import ccall safe "cometa_provider_new"
  cNew :: StablePtr state -> FunPtr (ConfirmationCallback state) -> Ptr (Ptr NativeProvider) -> IO NativeCode

-- | Acquire an additional reference. Serialize this non-atomic count transition
-- with every retain and release through aliases of the same provider.
foreign import ccall safe "cometa_provider_ref"
  cRef :: Ptr NativeProvider -> IO ()

-- | Consume one reference after its operations have joined. Final destruction
-- frees the adopted runtime handles without invoking user cleanup callbacks.
foreign import ccall safe "cometa_provider_release"
  cRelease :: Ptr NativeProvider -> IO ()

-- | Borrow the provider and hash bytes for a synchronous callback-capable call.
-- The caller holds an operation reference until this call returns.
foreign import ccall safe "cometa_provider_confirm"
  cConfirm :: Ptr NativeProvider -> Ptr Word8 -> CSize -> Word64 -> Ptr CInt -> IO NativeCode

-- | Borrow the provider's diagnostic. Copy it before releasing the provider or
-- starting another operation, which may overwrite the same storage.
foreign import ccall safe "cometa_provider_error"
  cError :: Ptr NativeProvider -> IO CString

-- | Atomically read the number of native contexts rooting callback registrations.
foreign import ccall safe "cometa_callback_live_contexts"
  cLiveContexts :: IO CSize

-- | Atomically read the count of completed native calls, including hash cleanup.
foreign import ccall safe "cometa_callback_completed_calls"
  cCompletedCalls :: IO CSize
