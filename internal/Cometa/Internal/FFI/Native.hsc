{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Raw, private declarations. Headers determine the enum representation and
-- success constant. All input buffers are borrowed for the call; successful hash
-- output owns one reference. The data observer borrows from that reference.
-- No function in this module retains a Haskell buffer or invokes a callback.
-- Const-pointer observers use ccall because GHC's CAPI wrappers discard const;
-- their signatures are audited against the same pinned headers.
module Cometa.Internal.FFI.Native
  ( NativeHash,
    NativeCode,
    success,
    cCompute,
    cUnref,
    cData,
    cSize,
    cErrorMessage,
    cVersion,
  )
where

{- ORMOLU_DISABLE -}
#include <cardano/crypto/blake2b_hash.h>
#include <cardano/error.h>
{- ORMOLU_ENABLE -}

import Data.Word (Word32, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CSize (..))
import Foreign.Ptr (Ptr)

-- | Opaque native allocation; never dereferenced by Haskell.
data {-# CTYPE "cardano/crypto/blake2b_hash.h" "cardano_blake2b_hash_t" #-} NativeHash

-- | ABI representation of cardano_error_t, derived from the installed header.
{- ORMOLU_DISABLE -}
type NativeCode = #{type cardano_error_t}

-- | Header-defined success status.
success :: NativeCode
success = #{const CARDANO_SUCCESS}
{- ORMOLU_ENABLE -}

-- | Safe because hashing can take time proportional to unbounded input length.
foreign import capi safe "cardano/crypto/blake2b_hash.h cardano_blake2b_compute_hash"
  cCompute :: Ptr Word8 -> CSize -> CSize -> Ptr (Ptr NativeHash) -> IO NativeCode

-- | Nonblocking bounded destructor. Decrements the reference in the slot and
-- clears it when that reference was the final one. A released alias must not
-- be used again, even when another owner leaves the pointer non-null.
foreign import capi unsafe "cardano/crypto/blake2b_hash.h cardano_blake2b_hash_unref"
  cUnref :: Ptr (Ptr NativeHash) -> IO ()

-- | Borrowed bytes remain valid only while an owner retains the hash.
foreign import ccall unsafe "cardano_blake2b_hash_get_data"
  cData :: Ptr NativeHash -> IO (Ptr Word8)

-- | Digest byte length; the native function returns zero for a null hash.
foreign import capi unsafe "cardano/crypto/blake2b_hash.h cardano_blake2b_hash_get_bytes_size"
  cSize :: Ptr NativeHash -> IO CSize

-- | Returned string is static and must be copied, never freed.
foreign import ccall unsafe "cardano_error_to_string"
  cErrorMessage :: NativeCode -> IO CString

-- | Borrowed static, NUL-terminated version string; copy it and never free it.
foreign import ccall unsafe "cardano_get_lib_version"
  cVersion :: IO CString
