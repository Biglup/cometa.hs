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

-- | Standalone CBOR for native collection shapes. Association lists retain
-- explicit zero and repeated keys, unlike normalized asset bundles. All codecs
-- sort stably by encoded key byte length then lexicographic bytes. Equal keys
-- keep their relative order. These are semantic encodings, not original bytes.
--
-- @
-- import qualified Cometa.Encoding.Collections as Collections
--
-- emptyWithdrawals = Collections.encodeWithdrawalsCbor []
-- @
module Cometa.Encoding.Collections
  ( encodeAssetNamesCbor,
    decodeAssetNamesCbor,
    encodeWithdrawalsCbor,
    decodeWithdrawalsCbor,
    encodeHashesCbor,
    encodeHashesCborWith,
    decodeHashesCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import qualified Codec.CBOR.Term as T
import Cometa.Address.Reward (RewardAddress)
import qualified Cometa.Address.Reward as Reward
import Cometa.AssetName (AssetName)
import qualified Cometa.AssetName as Name
import Cometa.Crypto.Blake2b (Blake2bHash)
import qualified Cometa.Crypto.Blake2b as Hash
import Cometa.Encoding.Set (SetEncoding (..))
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as Cbor
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Word (Word64)

-- DEFINITIONS ----------------------------------------------------------------

-- | Encode one policy's asset-name quantities. Zero and duplicate entries are
-- retained, including empty names. Quantities must fit signed 64 bits;
-- otherwise return 'InvalidValueQuantity'. Empty input encodes an empty map.
encodeAssetNamesCbor :: [(AssetName, Integer)] -> Either Error ByteString
encodeAssetNamesCbor pairs = do
  mapM_ validate pairs
  pure (encodeMap Name.toBytes E.encodeInteger pairs)
  where
    validate (_, amount)
      | amount < toInteger (minBound :: Int64) || amount > toInteger (maxBound :: Int64) = Left (InvalidValueQuantity amount)
      | otherwise = Right ()

-- | Decode a complete definite or indefinite asset-name map, retaining zero and
-- duplicate entries. Names must contain at most 32 bytes and quantities must fit
-- signed 64 bits. Malformed maps return 'InvalidValueCbor'.
decodeAssetNamesCbor :: ByteString -> Either Error [(AssetName, Integer)]
decodeAssetNamesCbor = Cbor.decodeAs InvalidValueCbor $ do
  pairs <- Cbor.entries ((,) <$> checked Name.fromBytes <*> (toInteger <$> D.decodeInt64))
  pure (ordered (Name.toBytes . fst) pairs)

-- | Encode reward accounts and unsigned lovelace amounts. Zero and duplicate
-- entries are retained; empty input is an empty map, not absent withdrawals.
-- Amounts span the full unsigned 64-bit range, independent of builder limits.
encodeWithdrawalsCbor :: [(RewardAddress, Word64)] -> ByteString
encodeWithdrawalsCbor = encodeMap Reward.toBytes E.encodeWord64

-- | Decode a complete definite or indefinite withdrawal map, including empty
-- maps, zero and duplicate entries. Keys must be exact reward-account bytes;
-- negative or oversized amounts and malformed keys return 'InvalidTransactionCbor'.
decodeWithdrawalsCbor :: ByteString -> Either Error [(RewardAddress, Word64)]
decodeWithdrawalsCbor = Cbor.decodeAs InvalidTransactionCbor $ do
  pairs <- Cbor.entries ((,) <$> checked Reward.fromBytes <*> D.decodeWord64)
  pure (ordered (Reward.toBytes . fst) pairs)

-- | Encode variable-length nonempty digests as a tag-258 array. Despite the
-- native name “hash set”, duplicate digests are retained. Empty input is valid.
encodeHashesCbor :: [Blake2bHash] -> ByteString
encodeHashesCbor = encodeHashesCborWith TaggedSet

-- | Choose whether a freshly encoded digest array carries tag 258. Ordering
-- and duplicate retention match 'encodeHashesCbor'.
encodeHashesCborWith :: SetEncoding -> [Blake2bHash] -> ByteString
encodeHashesCborWith style hashes =
  Cbor.encode $
    tag
      <> E.encodeListLen (fromIntegral (length hashes))
      <> foldMap (E.encodeBytes . Hash.toBytes) (ordered Hash.toBytes hashes)
  where
    tag = case style of
      TaggedSet -> E.encodeTag 258
      UntaggedSet -> mempty

-- | Decode a complete definite or indefinite digest array, optionally tagged
-- 258. Each digest must be a definite-length nonempty byte string, matching
-- the native hash reader; hash lengths may differ. Duplicate hashes
-- survive decoding. Wrong tags, empty hashes and malformed input return
-- 'InvalidHashCbor'. The tag is not retained by this semantic decoder.
decodeHashesCbor :: ByteString -> Either Error [Blake2bHash]
decodeHashesCbor =
  Cbor.decodeAs InvalidHashCbor $
    ordered Hash.toBytes <$> Cbor.setList (D.decodeBytes >>= either (fail . show) pure . Hash.fromBytes)

encodeMap :: (a -> ByteString) -> (b -> E.Encoding) -> [(a, b)] -> ByteString
encodeMap key value pairs =
  Cbor.encode $
    E.encodeMapLen (fromIntegral (length pairs))
      <> foldMap (\(k, v) -> E.encodeBytes (key k) <> value v) (ordered (key . fst) pairs)

ordered :: (a -> ByteString) -> [a] -> [a]
ordered bytes = sortOn (\value -> let key = bytes value in (B.length key, key))

checked :: (ByteString -> Either Error a) -> D.Decoder s a
checked constructor = do
  term <- T.decodeTerm
  bytes <- case term of
    T.TBytes value -> pure value
    T.TBytesI value -> pure (L.toStrict value)
    _ -> fail "Expected byte string"
  either (fail . show) pure (constructor bytes)
