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

-- | One CBOR item with its exact encoding preserved. Equality and ordering
-- compare encoded bytes, so different encodings of the same value can differ.
-- Construction checks that the native reader accepts exactly one complete item;
-- it does not enforce canonical encoding, schema rules, tag semantics, or UTF-8
-- validity of arbitrary nested text. 'decodeText' validates UTF-8 explicitly.
--
-- Scalar codecs and ordered collection codecs construct and inspect ordinary
-- Haskell values. Collection encoding preserves the exact bytes of each child.
--
-- @
-- import qualified Cometa.Encoding.Cbor as Cbor
--
-- main :: IO ()
-- main = do
--   result <- Cbor.encodeInteger 42
--   print (Cbor.toHex <$> result)
-- @
module Cometa.Encoding.Cbor
  ( Cbor,

    -- * Import and exact representation
    fromBytes,
    fromHex,
    toBytes,
    toHex,

    -- * Primitive values
    encodeInteger,
    decodeInteger,
    encodeByteString,
    decodeByteString,
    encodeText,
    decodeText,
    encodeBool,
    decodeBool,
    decodeDouble,
    decodeSimple,
    encodeUndefined,

    -- * Ordered collections
    encodeArray,
    decodeArray,
    encodeMap,
    decodeMap,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Internal.Error (fromNativeFailure)
import qualified Cometa.Internal.FFI.Cbor as Native
import qualified Cometa.Internal.FFI.Native as Status
import Cometa.Internal.Failure (NativeFailure (..))
import qualified Cometa.Internal.Hex as Hex
import Cometa.Internal.Ownership (copyStaticText, withOwnedOutput)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CDouble (..), CInt, CSize)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

-- TYPES ----------------------------------------------------------------------

-- | A complete, native-reader-accepted CBOR item. Encoded bytes are retained
-- without normalization. Equality is representation-sensitive; ordering is
-- lexicographic byte ordering. 'Show' is diagnostic, not an interchange format.
newtype Cbor = Cbor ByteString
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Accept exactly one complete item, preserving all input bytes. Empty input,
-- malformed structures and trailing bytes return 'NativeError'. This structural
-- check does not assert schema, tag semantics, canonicality, or nested UTF-8.
-- Allocation and decoding failures return 'NativeError'.
fromBytes :: ByteString -> IO (Either Error Cbor)
fromBytes bytes = withBytes bytes $ \input size ->
  fmap (const (Cbor bytes)) <$> runStatus "cbor.fromBytes" (Native.cValidate input size)

-- | Accept nonempty, even-length ASCII hexadecimal text in either case, with
-- no whitespace or prefix, then perform 'fromBytes' validation. Malformed hex
-- returns 'InvalidHex'. The resulting bytes retain their original CBOR form.
fromHex :: Text -> IO (Either Error Cbor)
fromHex text
  | Text.null text = pure (Left InvalidHex)
  | otherwise = maybe (pure (Left InvalidHex)) fromBytes (Hex.decodeHex text)

-- | Retrieve the exact encoded item bytes without normalization.
toBytes :: Cbor -> ByteString
toBytes (Cbor bytes) = bytes

-- | Encode the exact item bytes as lowercase ASCII hex, without a prefix.
toHex :: Cbor -> Text
toHex = Hex.encodeHex . toBytes

-- | Encode an untagged primitive integer using the shortest native encoding.
-- The supported inclusive range is @-2^64@ through @2^64 - 1@. Values outside
-- this range return 'InvalidCborInteger'; tagged bignums are not encoded here.
encodeInteger :: Integer -> IO (Either Error Cbor)
encodeInteger value
  | value < negate (2 ^ (64 :: Int)) || value >= 2 ^ (64 :: Int) = pure (Left (InvalidCborInteger value))
  | otherwise = encodeResult "cbor.encodeInteger" (Native.cEncodeInteger (flag (value < 0)) argument)
  where
    argument = fromInteger (if value < 0 then negate value - 1 else value)

-- | Decode an untagged primitive integer exactly, including the full unsigned
-- and negative 64-bit CBOR ranges. Tagged bignums and other types return
-- 'NativeError'. Nonminimal integer encodings are accepted without modification.
decodeInteger :: Cbor -> IO (Either Error Integer)
decodeInteger cbor = withBytes (toBytes cbor) $ \input size ->
  alloca $ \negative -> alloca $ \argument ->
    withDiagnostic $ \diagnostic capacity -> do
      code <- Native.cDecodeInteger input size negative argument diagnostic capacity
      statusResult "cbor.decodeInteger" code $ do
        sign <- peek negative
        magnitude <- toInteger <$> peek argument
        pure (if sign /= 0 then negate magnitude - 1 else magnitude)

-- | Encode bytes as a definite-length CBOR byte string. Empty bytes are valid.
encodeByteString :: ByteString -> IO (Either Error Cbor)
encodeByteString = encodeString "cbor.encodeByteString" False

-- | Decode a CBOR byte string, concatenating indefinite-length chunks in order.
-- Empty strings are valid. Other types return 'NativeError'.
decodeByteString :: Cbor -> IO (Either Error ByteString)
decodeByteString = decodeString "cbor.decodeByteString" False

-- | Encode Unicode text as one definite-length UTF-8 CBOR text string.
-- Empty text and embedded NUL characters are preserved.
encodeText :: Text -> IO (Either Error Cbor)
encodeText = encodeString "cbor.encodeText" True . Text.encodeUtf8

-- | Decode a CBOR text string and validate UTF-8. Each indefinite-length
-- chunk must independently contain valid UTF-8; multibyte sequences cannot span
-- chunk boundaries. Invalid UTF-8 returns 'InvalidCborUtf8'; structural or type
-- failures return 'NativeError'. Empty text and embedded NUL characters survive.
decodeText :: Cbor -> IO (Either Error Text)
decodeText cbor = case ByteString.uncons (toBytes cbor) of
  Just (127, body) -> case ByteString.unsnoc body of
    Just (interior, 255) -> do
      chunks <- readTextChunks interior
      case chunks of
        Left failure -> pure (Left failure)
        Right values -> decodeTextValues [] values
    _ -> pure (Left (NativeContractViolation "cbor.decodeText"))
  _ -> decodeTextValue cbor

-- | Encode a Boolean as its native CBOR simple value.
encodeBool :: Bool -> IO (Either Error Cbor)
encodeBool value = encodeResult "cbor.encodeBool" (Native.cEncodeBool (flag value))

-- | Decode an untagged Boolean. Null, undefined and other types return 'NativeError'.
decodeBool :: Cbor -> IO (Either Error Bool)
decodeBool cbor = withBytes (toBytes cbor) $ \input size -> alloca $ \output ->
  withDiagnostic $ \diagnostic capacity -> do
    code <- Native.cDecodeBool input size output diagnostic capacity
    statusResult "cbor.decodeBool" code ((/= 0) <$> peek output)

-- | Decode an untagged IEEE half-, single- or double-precision value as a
-- 'Double'. Signed zero, infinities and NaN are accepted. Integer items are not
-- coerced to floating point; other types return 'NativeError'. The original
-- encoding remains unchanged. NaN payload bits are not an interchange guarantee.
decodeDouble :: Cbor -> IO (Either Error Double)
decodeDouble cbor = withBytes (toBytes cbor) $ \input size -> alloca $ \output ->
  withDiagnostic $ \diagnostic capacity -> do
    code <- Native.cDecodeDouble input size output diagnostic capacity
    statusResult "cbor.decodeDouble" code ((\(CDouble value) -> value) <$> peek output)

-- | Decode the number of a simple value: false is 20, true is 21, null is 22
-- and undefined is 23. Unassigned byte values and nonminimal two-byte encodings
-- accepted by the reader are retained. Floating-point and other major types
-- return 'NativeError'. This does not interpret application-specific meanings.
decodeSimple :: Cbor -> IO (Either Error Word8)
decodeSimple cbor = withBytes (toBytes cbor) $ \input size -> alloca $ \output ->
  withDiagnostic $ \diagnostic capacity -> do
    code <- Native.cDecodeSimple input size output diagnostic capacity
    statusResult "cbor.decodeSimple" code (peek output)

-- | Encode CBOR undefined (@f7@), distinct from null, an absent field and false.
-- Use 'decodeSimple' to inspect its simple-value number, 23.
encodeUndefined :: IO (Either Error Cbor)
encodeUndefined = encodeResult "cbor.encodeUndefined" Native.cEncodeUndefined

-- | Encode an array in list order with a definite-length outer encoding.
-- Every child's bytes remain exact, including nonminimal or indefinite forms.
encodeArray :: [Cbor] -> IO (Either Error Cbor)
encodeArray items = encodeCollection "cbor.encodeArray" False (length items) items

-- | Decode a definite or indefinite array into its ordered encoded children.
-- Child bytes remain exact. Other types return 'NativeError'.
decodeArray :: Cbor -> IO (Either Error [Cbor])
decodeArray = decodeCollection "cbor.decodeArray" False

-- | Encode map entries in list order, preserving duplicate keys. The outer
-- map uses definite length; every encoded key and value remains byte-exact.
-- No sorting, key deduplication, or schema validation is performed.
encodeMap :: [(Cbor, Cbor)] -> IO (Either Error Cbor)
encodeMap entries = encodeCollection "cbor.encodeMap" True (length entries) (concatMap (\(key, value) -> [key, value]) entries)

-- | Decode a definite or indefinite map into ordered key/value pairs,
-- preserving duplicate keys and each child's exact encoding. Other types
-- return 'NativeError'. Missing values are structural decoding failures.
decodeMap :: Cbor -> IO (Either Error [(Cbor, Cbor)])
decodeMap cbor = do
  result <- decodeCollection "cbor.decodeMap" True cbor
  pure (result >>= pairEntries [])
  where
    pairEntries accumulated [] = Right (reverse accumulated)
    pairEntries accumulated (key : value : rest) = pairEntries ((key, value) : accumulated) rest
    pairEntries _ [_] = Left (NativeContractViolation "cbor.decodeMap")

-- | Validate chunks one at a time, stopping at the first failure. Only copied
-- Haskell values remain live while the final text is concatenated.
decodeTextValues :: [Text] -> [Cbor] -> IO (Either Error Text)
decodeTextValues accumulated [] = pure (Right (Text.concat (reverse accumulated)))
decodeTextValues accumulated (value : rest) = do
  result <- decodeTextValue value
  case result of
    Left failure -> pure (Left failure)
    Right text -> decodeTextValues (text : accumulated) rest

-- | Check UTF-8 after the native text buffer has been copied and released.
decodeTextValue :: Cbor -> IO (Either Error Text)
decodeTextValue cbor = do
  result <- decodeString "cbor.decodeText" True cbor
  pure $ case result of
    Left failure -> Left failure
    Right bytes -> case Text.decodeUtf8' bytes of
      Left _ -> Left InvalidCborUtf8
      Right text -> Right text

encodeString :: Text -> Bool -> ByteString -> IO (Either Error Cbor)
encodeString operation text bytes = withBytes bytes $ \input size ->
  encodeResult operation (Native.cEncodeString (flag text) input size)

decodeString :: Text -> Bool -> Cbor -> IO (Either Error ByteString)
decodeString operation text cbor = withBytes (toBytes cbor) $ \input size ->
  withDiagnostic $ \diagnostic capacity ->
    copyBuffer operation (\output -> Native.cDecodeString (flag text) input size output diagnostic capacity)

encodeCollection :: Text -> Bool -> Int -> [Cbor] -> IO (Either Error Cbor)
encodeCollection operation mapEntries count items =
  withBytes (ByteString.concat (map toBytes items)) $ \input size ->
    encodeResult operation (Native.cEncodeCollection (flag mapEntries) (fromIntegral count) input size)

-- | Keep one reader alive through the complete cursor loop. Each child buffer
-- is copied and released before the next iteration; one end-state slot is reused.
decodeCollection :: Text -> Bool -> Cbor -> IO (Either Error [Cbor])
decodeCollection operation mapEntries cbor = withBytes (toBytes cbor) $ \input size ->
  withDiagnostic $ \diagnostic capacity ->
    withOwnedOutput operation Native.cReaderUnref (\output -> Native.cReaderNew input size output diagnostic capacity) $ \reader -> do
      code <- Native.cCollectionStart reader (flag mapEntries) diagnostic capacity
      if code /= Status.success
        then statusResult operation code (pure [])
        else alloca $ \atEnd -> readChildren reader diagnostic capacity atEnd []
  where
    readChildren reader diagnostic capacity atEnd accumulated = do
      code <- Native.cCollectionAtEnd reader (flag mapEntries) atEnd diagnostic capacity
      if code /= Status.success
        then statusResult operation code (pure [])
        else do
          finished <- (/= 0) <$> peek atEnd
          if finished
            then do
              endCode <- Native.cCollectionEnd reader (flag mapEntries) diagnostic capacity
              statusResult operation endCode (pure (reverse accumulated))
            else do
              child <- copyBuffer operation (\output -> Native.cReadItem reader output diagnostic capacity)
              case child of
                Left failure -> pure (Left failure)
                Right bytes -> readChildren reader diagnostic capacity atEnd (Cbor bytes : accumulated)

-- | Re-read the interior of a validated indefinite text item as definite text
-- chunks. Each copied chunk outlives its native buffer; one scoped reader owns
-- the cursor. A decreasing byte count prevents a non-advancing native loop.
readTextChunks :: ByteString -> IO (Either Error [Cbor])
readTextChunks bytes
  | ByteString.null bytes = pure (Right [])
  | otherwise = withBytes bytes $ \input size ->
      withDiagnostic $ \diagnostic capacity ->
        withOwnedOutput "cbor.decodeText" Native.cReaderUnref (\output -> Native.cReaderNew input size output diagnostic capacity) $ \reader ->
          alloca $ \remaining -> readChunks reader diagnostic capacity remaining Nothing []
  where
    readChunks reader diagnostic capacity remaining previous accumulated = do
      code <- Native.cReaderRemaining reader remaining diagnostic capacity
      if code /= Status.success
        then statusResult "cbor.decodeText" code (pure [])
        else do
          count <- peek remaining
          if count == 0
            then pure (Right (reverse accumulated))
            else
              if maybe False (count >=) previous
                then pure (Left (NativeContractFailure "cbor.decodeText"))
                else do
                  chunk <- copyBuffer "cbor.decodeText" (\output -> Native.cReadTextChunk reader output diagnostic capacity)
                  case chunk of
                    Left failure -> pure (Left failure)
                    Right value -> readChunks reader diagnostic capacity remaining (Just count) (Cbor value : accumulated)

-- | Copy and release one owned writer result before constructing a Cbor value.
-- Unlike decoded string content, an encoded item must never be empty.
encodeResult :: Text -> (Ptr (Ptr Native.NativeBuffer) -> CString -> CSize -> IO Status.NativeCode) -> IO (Either Error Cbor)
encodeResult operation encode = do
  result <- withDiagnostic $ \diagnostic capacity -> copyBuffer operation (\output -> encode output diagnostic capacity)
  pure $ case result of
    Left failure -> Left failure
    Right bytes
      | ByteString.null bytes -> Left (NativeContractViolation operation)
      | otherwise -> Right (Cbor bytes)

-- | Consume one output reference on every exit, including partial native
-- failures. Copy borrowed storage before release; a zero-length decoded string
-- is valid even when its native buffer has no data pointer.
copyBuffer :: Text -> (Ptr (Ptr Native.NativeBuffer) -> IO Status.NativeCode) -> IO (Either NativeFailure ByteString)
copyBuffer operation acquire = withOwnedOutput operation Native.cBufferUnref acquire $ \buffer -> do
  size <- Native.cBufferSize buffer
  storage <- Native.cBufferData buffer
  if toInteger size > toInteger (maxBound :: Int) || (size /= 0 && storage == nullPtr)
    then pure (Left (NativeContractFailure operation))
    else
      if size == 0
        then pure (Right ByteString.empty)
        else Right <$> ByteString.packCStringLen (castPtr storage, fromIntegral size)

runStatus :: Text -> (CString -> CSize -> IO Status.NativeCode) -> IO (Either Error ())
runStatus operation call = withDiagnostic $ \diagnostic capacity -> do
  code <- call diagnostic capacity
  statusResult operation code (pure ())

-- | Inspect output slots only after success; preserve exact native status codes.
statusResult :: Text -> Status.NativeCode -> IO value -> IO (Either NativeFailure value)
statusResult operation code action
  | code == Status.success = Right <$> action
  | otherwise = do
      message <- Status.cErrorMessage code >>= copyStaticText
      pure (Left (NativeFailure operation (toInteger code) message))

-- | Keep caller-owned diagnostic storage alive through the native operation
-- and its cleanup, then copy a failure message before releasing that storage.
-- Acquisition helpers retain responsibility for all owned output references.
withDiagnostic :: (CString -> CSize -> IO (Either NativeFailure value)) -> IO (Either Error value)
withDiagnostic action = allocaBytes 1024 $ \diagnostic -> do
  poke diagnostic 0
  result <- action diagnostic 1024
  case result of
    Right value -> pure (Right value)
    Left failure@(NativeContractFailure _) -> pure (Left (fromNativeFailure failure))
    Left (NativeFailure operation code fallback) -> do
      message <- copyStaticText diagnostic
      pure (Left (fromNativeFailure (NativeFailure operation code (if Text.null message then fallback else message))))

-- | Borrow immutable Haskell bytes for one synchronous native scope. C must
-- finish using the pointer before this continuation returns.
withBytes :: ByteString -> (Ptr Word8 -> CSize -> IO value) -> IO value
withBytes bytes action = ByteString.useAsCStringLen bytes $ \(storage, size) -> action (castPtr storage) (fromIntegral size)

flag :: Bool -> CInt
flag value = if value then 1 else 0
