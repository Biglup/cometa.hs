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

-- | Exact nested transaction CBOR slices and schema combinators.
module Cometa.Internal.TransactionCbor (decode, decodeAs, encode, raw, nested, array, list, entries, setList, optional, slice, mapFields) where

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Read as R
import qualified Codec.CBOR.Term as T
import qualified Codec.CBOR.Write as W
import Cometa.Error (Error (..))
import qualified Cometa.Internal.ProposalCbor as P
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

encode :: E.Encoding -> ByteString
encode = W.toStrictByteString

decode :: (forall s. D.Decoder s a) -> ByteString -> Either Error a
decode = decodeAs InvalidTransactionCbor

-- | Preserve the caller's domain error at complete-CBOR boundaries.
decodeAs :: (Text -> Error) -> (forall s. D.Decoder s a) -> ByteString -> Either Error a
decodeAs failure parser bytes = case R.deserialiseFromBytes parser (L.fromStrict bytes) of
  Left problem -> Left (failure (Text.pack (show problem)))
  Right (rest, value)
    | L.null rest -> Right value
    | otherwise -> Left (failure "Trailing transaction CBOR")

raw :: ByteString -> E.Encoding
raw = E.encodePreEncoded

-- | Extract bytes by original offsets; Term is used only to advance the decoder.
slice :: ByteString -> D.Decoder s ByteString
slice bytes = do
  (_, start, end) <- D.decodeWithByteSpan T.decodeTerm
  pure (B.take (fromIntegral (end - start)) (B.drop (fromIntegral start) bytes))

nested :: ByteString -> (ByteString -> Either Error a) -> D.Decoder s a
nested bytes parser = slice bytes >>= either (fail . show) pure . parser

array :: Int -> D.Decoder s a -> D.Decoder s a
array = P.array

list :: D.Decoder s a -> D.Decoder s [a]
list = P.list

entries :: D.Decoder s a -> D.Decoder s [a]
entries = P.entries

setList :: D.Decoder s a -> D.Decoder s [a]
setList = P.setList

optional :: D.Decoder s a -> D.Decoder s (Maybe a)
optional = P.optional

mapFields :: ByteString -> D.Decoder s (Map Word64 ByteString)
mapFields bytes = do
  pairs <- entries ((,) <$> D.decodeWord64 <*> slice bytes)
  let result = Map.fromList pairs
  unless (Map.size result == length pairs) (fail "Duplicate transaction map key")
  pure result
