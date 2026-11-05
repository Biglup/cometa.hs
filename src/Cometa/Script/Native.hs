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

-- | Native signature, threshold, time and Dijkstra guard scripts. Values own
-- their exact CBOR encoding. Equality and ordering compare that encoding, so
-- semantically equivalent nonminimal encodings can differ. Slot numbers count
-- slots, with an inclusive lower bound and exclusive upper bound.
--
-- @
-- import qualified Cometa.Script.Native as Native
--
-- window :: Native.NativeScript
-- window = Native.allOf [Native.invalidBefore 100, Native.invalidAfter 200]
-- @
module Cometa.Script.Native
  ( -- * Script values
    NativeScript,
    NativeScriptView (..),

    -- * Conditions
    signature,
    allOf,
    anyOf,
    atLeast,
    invalidBefore,
    invalidAfter,
    requireGuard,

    -- * Inspection and encoding
    view,
    encodeCbor,
    decodeCbor,

    -- * Script hash
    hash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import Cometa.Credential (Credential, Guard, KeyHash, Payment, ScriptHash)
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error (..))
import Control.Monad (replicateM, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | An immutable script with validated hash lengths and unsigned thresholds.
-- Imported script encodings are retained exactly, including child encodings.
-- 'Show' is diagnostic, not an interchange format.
data NativeScript = NativeScript !ByteString !NativeScriptView
  deriving (Show)

instance Eq NativeScript where
  left == right = encodeCbor left == encodeCbor right

instance Ord NativeScript where
  compare left right = compare (encodeCbor left) (encodeCbor right)

-- | Read-only alternatives. Construct scripts with the functions below;
-- inspecting this value cannot bypass credential validation.
data NativeScriptView
  = -- | Requires a payment verification-key signature.
    RequireSignature !(KeyHash Payment)
  | -- | All children must succeed; an empty list succeeds.
    RequireAll ![NativeScript]
  | -- | One or more children must succeed; an empty list fails.
    RequireAny ![NativeScript]
  | -- | Required count followed by ordered children; zero always succeeds.
    RequireAtLeast !Word64 ![NativeScript]
  | -- | Inclusive lower slot bound.
    InvalidBefore !Word64
  | -- | Exclusive upper slot bound.
    InvalidAfter !Word64
  | -- | Credential must be present in transaction guards (Dijkstra onwards).
    RequireGuard !(Credential Guard)
  deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Require a signature from this payment key hash.
signature :: KeyHash Payment -> NativeScript
signature key = assemble (RequireSignature key)

-- | Require every child in order. Empty input is an always-succeeding script.
allOf :: [NativeScript] -> NativeScript
allOf = assemble . RequireAll

-- | Require at least one child. Empty input is an always-failing script.
anyOf :: [NativeScript] -> NativeScript
anyOf = assemble . RequireAny

-- | Require this many successful children. Counts above the child count are
-- valid and deliberately unsatisfiable. Duplicate children retain their positions
-- and count separately; zero with no children is valid and always succeeds.
atLeast :: Word64 -> [NativeScript] -> NativeScript
atLeast required children = assemble (RequireAtLeast required children)

-- | Require the validity interval to start at or after the supplied slot.
invalidBefore :: Word64 -> NativeScript
invalidBefore = assemble . InvalidBefore

-- | Require the validity interval to end at or before the supplied exclusive
-- upper bound. Slot zero is valid and yields an unsatisfiable time restriction.
invalidAfter :: Word64 -> NativeScript
invalidAfter = assemble . InvalidAfter

-- | Require a key or script guard credential. This alternative requires
-- Dijkstra ledger support; construction does not assert era availability.
requireGuard :: Credential Guard -> NativeScript
requireGuard = assemble . RequireGuard

-- | Inspect the semantic alternative and its ordered children.
view :: NativeScript -> NativeScriptView
view (NativeScript _ alternative) = alternative

-- | Exact imported bytes, or a definite-length encoding for assembled values.
-- Assembling a parent preserves each child's exact encoding.
encodeCbor :: NativeScript -> ByteString
encodeCbor (NativeScript bytes _) = bytes

-- | Decode exactly one complete script, checking all alternatives and credential
-- hash lengths. Malformed, trailing or schema-invalid bytes
-- return 'InvalidScriptCbor'. Nonminimal and indefinite encodings are retained.
decodeCbor :: ByteString -> Either Error NativeScript
decodeCbor bytes = case Read.deserialiseFromBytes (decodeScript bytes) (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidScriptCbor (Text.pack (show failure)))
  Right (trailing, script)
    | Lazy.null trailing -> Right script
    | otherwise -> Left (InvalidScriptCbor "Trailing bytes after native script")

-- | Compute BLAKE2b-224 over byte zero followed by the exact script encoding.
-- Native hashing failures return 'Cometa.Error.NativeError'.
hash :: NativeScript -> IO (Either Error ScriptHash)
hash script = do
  result <- Blake2b.compute 28 (ByteString.cons 0 (encodeCbor script))
  pure (result >>= Credential.scriptHashFromBytes . Blake2b.toBytes)

assemble :: NativeScriptView -> NativeScript
assemble alternative = NativeScript (Write.toStrictByteString (encodeView alternative)) alternative

encodeView :: NativeScriptView -> Encode.Encoding
encodeView alternative = case alternative of
  RequireSignature key -> pair 0 (Encode.encodeBytes (Credential.keyHashBytes key))
  RequireAll children -> pair 1 (encodeChildren children)
  RequireAny children -> pair 2 (encodeChildren children)
  RequireAtLeast required children -> Encode.encodeListLen 3 <> Encode.encodeWord 3 <> Encode.encodeWord64 required <> encodeChildren children
  InvalidBefore slot -> pair 4 (Encode.encodeWord64 slot)
  InvalidAfter slot -> pair 5 (Encode.encodeWord64 slot)
  RequireGuard credential -> pair 6 (encodeCredential credential)
  where
    pair tag payload = Encode.encodeListLen 2 <> Encode.encodeWord tag <> payload

encodeChildren :: [NativeScript] -> Encode.Encoding
encodeChildren children = Encode.encodeListLen (fromIntegral (length children)) <> foldMap (Encode.encodePreEncoded . encodeCbor) children

encodeCredential :: Credential Guard -> Encode.Encoding
encodeCredential credential =
  Encode.encodeListLen 2 <> case credential of
    Credential.KeyCredential key -> Encode.encodeWord 0 <> Encode.encodeBytes (Credential.keyHashBytes key)
    Credential.ScriptCredential script -> Encode.encodeWord 1 <> Encode.encodeBytes (Credential.scriptHashBytes script)

-- Byte spans point into the immutable complete input; every child snapshot is
-- retained independently of the decoder and can safely be assembled elsewhere.
decodeScript :: ByteString -> Decode.Decoder s NativeScript
decodeScript bytes = do
  (alternative, start, end) <- Decode.decodeWithByteSpan decodeAlternative
  pure (NativeScript (ByteString.take (fromIntegral (end - start)) (ByteString.drop (fromIntegral start) bytes)) alternative)
  where
    decodeAlternative = do
      size <- Decode.decodeListLenOrIndef
      tag <- Decode.decodeWord
      let arity = if tag == 3 then 3 else 2
      unless (maybe True (== arity) size) (fail "Invalid native script arity")
      alternative <- case tag of
        0 -> RequireSignature <$> (decodeBytes >>= either (const (fail "Invalid signature hash length")) pure . Credential.keyHashFromBytes)
        1 -> RequireAll <$> decodeChildren bytes
        2 -> RequireAny <$> decodeChildren bytes
        3 -> do
          required <- Decode.decodeWord64
          children <- decodeChildren bytes
          pure (RequireAtLeast required children)
        4 -> InvalidBefore <$> Decode.decodeWord64
        5 -> InvalidAfter <$> Decode.decodeWord64
        6 -> RequireGuard <$> decodeCredential
        _ -> fail "Unknown native script alternative"
      finish size
      pure alternative

decodeChildren :: ByteString -> Decode.Decoder s [NativeScript]
decodeChildren bytes = do
  size <- Decode.decodeListLenOrIndef
  case size of
    Just count -> replicateM count (decodeScript bytes)
    Nothing -> loop []
  where
    loop accumulated = do
      ended <- Decode.decodeBreakOr
      if ended
        then pure (reverse accumulated)
        else do
          child <- decodeScript bytes
          loop (child : accumulated)

decodeCredential :: Decode.Decoder s (Credential Guard)
decodeCredential = do
  size <- Decode.decodeListLenOrIndef
  unless (maybe True (== 2) size) (fail "Invalid guard credential arity")
  tag <- Decode.decodeWord
  bytes <- decodeBytes
  credential <- case tag of
    0 -> either (const (fail "Invalid guard key hash length")) (pure . Credential.KeyCredential) (Credential.keyHashFromBytes bytes)
    1 -> either (const (fail "Invalid guard script hash length")) (pure . Credential.ScriptCredential) (Credential.scriptHashFromBytes bytes)
    _ -> fail "Unknown guard credential alternative"
  finish size
  pure credential

finish :: Maybe Int -> Decode.Decoder s ()
finish size = case size of
  Just _ -> pure ()
  Nothing -> do
    ended <- Decode.decodeBreakOr
    unless ended (fail "Unexpected script array field")

decodeBytes :: Decode.Decoder s ByteString
decodeBytes = do
  token <- Decode.peekTokenType
  if token == Decode.TypeBytesIndef
    then do
      Decode.decodeBytesIndef
      loop []
    else Decode.decodeBytes
  where
    loop accumulated = do
      ended <- Decode.decodeBreakOr
      if ended
        then pure (ByteString.concat (reverse accumulated))
        else do
          chunk <- Decode.decodeBytes
          loop (chunk : accumulated)
