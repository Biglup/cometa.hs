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

-- | Private, synchronous CBOR adapters. Native enums and bools are converted in
-- C. Input bytes are borrowed for each call; every output buffer and reader
-- owns one reference, including partial failure outputs. No user callback runs.
-- Native skip traversal uses an iterative loop and heap-backed nested frames;
-- collection extraction also iterates without recursive native descent.
module Cometa.Internal.FFI.Cbor
  ( NativeBuffer,
    NativeReader,
    cValidate,
    cEncodeInteger,
    cDecodeInteger,
    cEncodeString,
    cDecodeString,
    cEncodeBool,
    cDecodeBool,
    cEncodeUndefined,
    cDecodeDouble,
    cDecodeSimple,
    cEncodeCollection,
    cReaderNew,
    cCollectionStart,
    cCollectionAtEnd,
    cCollectionEnd,
    cReadItem,
    cReaderRemaining,
    cReadTextChunk,
    cReaderUnref,
    cBufferUnref,
    cBufferData,
    cBufferSize,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.FFI.Native (NativeCode)
import Data.Word (Word64, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CDouble (..), CInt (..), CSize (..), CUInt (..))
import Foreign.Ptr (Ptr)

-- TYPES ----------------------------------------------------------------------

-- | Opaque owned native byte storage.
data NativeBuffer

-- | Opaque owned reader containing a copy of its input bytes.
data NativeReader

-- FOREIGN IMPORTS ------------------------------------------------------------

-- All potentially input-proportional operations are safe and non-interruptible.
-- The final CString/CSize arguments are caller-owned diagnostic storage/capacity.
foreign import ccall safe "cometa_cbor_validate"
  cValidate :: Ptr Word8 -> CSize -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_encode_integer"
  cEncodeInteger :: CInt -> Word64 -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_decode_integer"
  cDecodeInteger :: Ptr Word8 -> CSize -> Ptr CInt -> Ptr Word64 -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_encode_string"
  cEncodeString :: CInt -> Ptr Word8 -> CSize -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_decode_string"
  cDecodeString :: CInt -> Ptr Word8 -> CSize -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_encode_bool"
  cEncodeBool :: CInt -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_decode_bool"
  cDecodeBool :: Ptr Word8 -> CSize -> Ptr CInt -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_encode_collection"
  cEncodeCollection :: CInt -> CSize -> Ptr Word8 -> CSize -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_reader_new"
  cReaderNew :: Ptr Word8 -> CSize -> Ptr (Ptr NativeReader) -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_collection_start"
  cCollectionStart :: Ptr NativeReader -> CInt -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_collection_at_end"
  cCollectionAtEnd :: Ptr NativeReader -> CInt -> Ptr CInt -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_collection_end"
  cCollectionEnd :: Ptr NativeReader -> CInt -> CString -> CSize -> IO NativeCode

foreign import ccall safe "cometa_cbor_read_item"
  cReadItem :: Ptr NativeReader -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

-- | Inspect unread bytes without exposing native reader state layout.
foreign import ccall safe "cometa_cbor_reader_remaining"
  cReaderRemaining :: Ptr NativeReader -> Ptr CSize -> CString -> CSize -> IO NativeCode

-- | Read one definite text chunk, rejecting tags and nested indefinite chunks.
foreign import ccall safe "cometa_cbor_read_text_chunk"
  cReadTextChunk :: Ptr NativeReader -> Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

-- | Reader destruction may release input-proportional nested frame storage.
foreign import ccall safe "cometa_cbor_reader_unref"
  cReaderUnref :: Ptr (Ptr NativeReader) -> IO ()

-- | Bounded buffer reference release; no callback or blocking operation runs.
foreign import ccall unsafe "cometa_cbor_buffer_unref"
  cBufferUnref :: Ptr (Ptr NativeBuffer) -> IO ()

-- | Borrow storage until buffer release; zero-length buffers may return null.
foreign import ccall unsafe "cometa_cbor_buffer_data"
  cBufferData :: Ptr NativeBuffer -> IO (Ptr Word8)

-- | Bounded buffer length observer.
foreign import ccall unsafe "cometa_cbor_buffer_size"
  cBufferSize :: Ptr NativeBuffer -> IO CSize

-- | Return an owned encoding of undefined; diagnostics use caller storage.
foreign import ccall safe "cometa_cbor_encode_undefined"
  cEncodeUndefined :: Ptr (Ptr NativeBuffer) -> CString -> CSize -> IO NativeCode

-- | Read a copied floating-point result; output is inspected only on success.
foreign import ccall safe "cometa_cbor_decode_double"
  cDecodeDouble :: Ptr Word8 -> CSize -> Ptr CDouble -> CString -> CSize -> IO NativeCode

-- | Read a simple-value number through a fixed-width byte, not an enum ABI.
foreign import ccall safe "cometa_cbor_decode_simple"
  cDecodeSimple :: Ptr Word8 -> CSize -> Ptr Word8 -> CString -> CSize -> IO NativeCode
