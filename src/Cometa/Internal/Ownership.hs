{-# LANGUAGE OverloadedStrings #-}

-- | Scoped native acquisition. Initialize the output slot before calling C,
-- release even partial failure results, and copy data before releasing its owner.
-- 'bracket' installs cleanup before the acquisition call in its unmasked body.
-- A safe, non-interruptible FFI call finishes writing its output slot before a
-- pending asynchronous exception unwinds the scope and releases that output.
module Cometa.Internal.Ownership
  ( copyHashResult,
    copyStaticText,
  )
where

import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.Native as Native
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import Foreign.C.String (CString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- | Copy a static UTF-8 diagnostic. Native diagnostics are expected to be UTF-8;
-- invalid sequences are replaced rather than raising an unrelated exception.
copyStaticText :: CString -> IO Text
copyStaticText pointer =
  if pointer == nullPtr
    then pure ""
    else Text.decodeUtf8With Text.lenientDecode <$> ByteString.packCString pointer

-- | Consume exactly one native output reference on every exit path. The result
-- contains no native pointers. A success with null storage is a contract failure.
copyHashResult :: Text -> (Ptr (Ptr Native.NativeHash) -> IO Native.NativeCode) -> IO (Either Error ByteString)
copyHashResult operation acquire =
  alloca $ \slot ->
    bracket (poke slot nullPtr >> pure slot) Native.cUnref $ \output -> do
      code <- acquire output
      if code /= Native.success
        then do
          message <- Native.cErrorMessage code >>= copyStaticText
          pure (Left (NativeError operation (toInteger code) message))
        else do
          hash <- peek output
          if hash == nullPtr
            then pure (Left (NativeContractViolation operation))
            else do
              size <- Native.cSize hash
              bytes <- Native.cData hash
              if bytes == nullPtr || size == 0 || toInteger size > toInteger (maxBound :: Int)
                then pure (Left (NativeContractViolation operation))
                else Right <$> ByteString.packCStringLen (castPtr bytes, fromIntegral size)
