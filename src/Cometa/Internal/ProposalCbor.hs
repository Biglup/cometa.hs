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
{-# LANGUAGE RankNTypes #-}

-- | Private complete CBOR decoding and nested semantic-codec composition.
-- No native objects or arbitrary effect boundaries are involved.
module Cometa.Internal.ProposalCbor
  ( encode,
    decode,
    raw,
    nested,
    array,
    finishArray,
    list,
    entries,
    optional,
    maybeEncoding,
    credentialEncoding,
    credentialDecoder,
    uniqueMap,
    setList,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Read as R
import qualified Codec.CBOR.Term as T
import qualified Codec.CBOR.Write as W
import qualified Cometa.Credential as C
import Cometa.Error (Error (..))
import Control.Monad (foldM, replicateM, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text

-- DEFINITIONS ----------------------------------------------------------------

encode :: E.Encoding -> ByteString
encode = W.toStrictByteString

decode :: (forall s. D.Decoder s a) -> ByteString -> Either Error a
decode parser bytes = case R.deserialiseFromBytes parser (L.fromStrict bytes) of
  Left failure -> Left (InvalidProposalCbor (Text.pack (show failure)))
  Right (rest, value)
    | L.null rest -> Right value
    | otherwise -> Left (InvalidProposalCbor "Trailing proposal CBOR")

raw :: ByteString -> E.Encoding
raw = E.encodePreEncoded

nested :: (ByteString -> Either Error a) -> D.Decoder s a
nested parser = do
  term <- T.decodeTerm
  either (fail . show) pure (parser (encode (T.encodeTerm term)))

array :: Int -> D.Decoder s a -> D.Decoder s a
array count parser = do
  size <- D.decodeListLenOrIndef
  case size of
    Just actual -> unless (actual == count) (fail "Incorrect proposal array arity")
    Nothing -> pure ()
  value <- parser
  finishArray size
  pure value

finishArray :: Maybe Int -> D.Decoder s ()
finishArray size = case size of
  Just _ -> pure ()
  Nothing -> do
    ended <- D.decodeBreakOr
    unless ended (fail "Extra proposal array elements")

list :: D.Decoder s a -> D.Decoder s [a]
list parser = D.decodeListLenOrIndef >>= sequenceLength parser

entries :: D.Decoder s a -> D.Decoder s [a]
entries parser = D.decodeMapLenOrIndef >>= sequenceLength parser

sequenceLength :: D.Decoder s a -> Maybe Int -> D.Decoder s [a]
sequenceLength parser size = case size of
  Just count -> replicateM count parser
  Nothing -> go
  where
    go = do
      ended <- D.decodeBreakOr
      if ended then pure [] else (:) <$> parser <*> go

optional :: D.Decoder s a -> D.Decoder s (Maybe a)
optional parser = do
  token <- D.peekTokenType
  if token == D.TypeNull then D.decodeNull >> pure Nothing else Just <$> parser

maybeEncoding :: (a -> E.Encoding) -> Maybe a -> E.Encoding
maybeEncoding = maybe E.encodeNull

credentialEncoding :: C.Credential purpose -> E.Encoding
credentialEncoding credential =
  E.encodeListLen 2 <> case credential of
    C.KeyCredential hash -> E.encodeWord 0 <> E.encodeBytes (C.keyHashBytes hash)
    C.ScriptCredential hash -> E.encodeWord 1 <> E.encodeBytes (C.scriptHashBytes hash)

credentialDecoder :: D.Decoder s (C.Credential purpose)
credentialDecoder = array 2 $ do
  kind <- D.decodeWord
  bytes <- D.decodeBytes
  case kind of
    0 -> either (fail . show) (pure . C.KeyCredential) (C.keyHashFromBytes bytes)
    1 -> either (fail . show) (pure . C.ScriptCredential) (C.scriptHashFromBytes bytes)
    _ -> fail "Invalid credential kind"

uniqueMap :: (Ord key) => Error -> [(key, value)] -> Either Error (Map key value)
uniqueMap duplicate = foldM insert Map.empty
  where
    insert values (key, value)
      | Map.member key values = Left duplicate
      | otherwise = Right (Map.insert key value values)

setList :: D.Decoder s a -> D.Decoder s [a]
setList parser = do
  token <- D.peekTokenType
  case token of
    D.TypeTag -> do
      tag <- D.decodeTag
      unless (tag == 258) (fail "Invalid set tag")
    _ -> pure ()
  list parser
