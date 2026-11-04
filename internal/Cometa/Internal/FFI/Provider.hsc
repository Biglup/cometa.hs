{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Private C adapter. The installed headers determine native enum values;
-- the adapter owns layout, native bool conversion and adopted runtime handles.
-- All entry points use safe calls, including reference destruction.
module Cometa.Internal.FFI.Provider
  ( NativeProvider,
    ConfirmationCallback,
    wrapConfirmation,
    success,
    failure,
    cNew,
    cRef,
    cRelease,
    cConfirm,
    cError,
    cLiveContexts,
    cCompletedCalls,
  )
where

{- ORMOLU_DISABLE -}
#include <cardano/error.h>
{- ORMOLU_ENABLE -}

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word64, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (FunPtr, Ptr)
import Foreign.StablePtr (StablePtr)

data NativeProvider

type ConfirmationCallback state = StablePtr state -> Ptr Word8 -> CSize -> Word64 -> Ptr CInt -> CString -> CSize -> IO CInt

{- ORMOLU_DISABLE -}
success :: CInt
success = #{const CARDANO_SUCCESS}

failure :: CInt
failure = #{const CARDANO_ERROR_GENERIC}
{- ORMOLU_ENABLE -}

foreign import ccall "wrapper"
  wrapConfirmation :: ConfirmationCallback state -> IO (FunPtr (ConfirmationCallback state))

foreign import ccall safe "cometa_provider_new"
  cNew :: StablePtr state -> FunPtr (ConfirmationCallback state) -> Ptr (Ptr NativeProvider) -> IO NativeCode

foreign import ccall safe "cometa_provider_ref"
  cRef :: Ptr NativeProvider -> IO ()

foreign import ccall safe "cometa_provider_release"
  cRelease :: Ptr NativeProvider -> IO ()

foreign import ccall safe "cometa_provider_confirm"
  cConfirm :: Ptr NativeProvider -> Ptr Word8 -> CSize -> Word64 -> Ptr CInt -> IO NativeCode

foreign import ccall safe "cometa_provider_error"
  cError :: Ptr NativeProvider -> IO CString

foreign import ccall safe "cometa_callback_live_contexts"
  cLiveContexts :: IO CSize

foreign import ccall safe "cometa_callback_completed_calls"
  cCompletedCalls :: IO CSize
