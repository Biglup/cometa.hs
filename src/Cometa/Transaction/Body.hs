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

-- | Transaction bodies with typed semantic fields and exact imported identity.
-- Construct a minimal body, update its typed fields, then retain 'EncodedBody'
-- for hashing or signing. Reassembling semantic fields deliberately produces a
-- fresh encoding and can change a transaction identifier.
--
-- @
-- minimal = body [] [] 0
-- @
module Cometa.Transaction.Body
  ( Body (..),
    body,
    fee,
    setFee,
    setFeeEncoded,
    encodeCbor,
    encodeCborWith,
    SetField (..),
    setEncoding,
    inputsAreTagged,
    withSetEncoding,
    EncodedBody,
    decodeCbor,
    fromBody,
    toBody,
    toCbor,
    hash,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Address.Reward (RewardAddress)
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Encoding.Set (SetEncoding (TaggedSet))
import Cometa.Error (Error (..))
import qualified Cometa.Internal.SetEncoding as SetEncoding
import qualified Cometa.Internal.TransactionCbor as Cbor
import Cometa.Internal.TransactionFields (BalanceInterval, Entries, Fields)
import qualified Cometa.Internal.TransactionFields as Fields
import Cometa.Protocol.ProposedUpdates (UpdateProposal)
import qualified Cometa.Protocol.ProposedUpdates as Updates
import Cometa.SubTransaction (SubTransaction)
import qualified Cometa.SubTransaction as Sub
import Cometa.Transaction.Input (Input)
import qualified Cometa.Transaction.Input as Input
import Cometa.Transaction.Output (Output)
import qualified Cometa.Transaction.Output as Output
import Cometa.TransactionId (TransactionId)
import qualified Cometa.TransactionId as Id
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Semantic transaction-body data. Equality includes field presence, list order,
-- and exact encodings of embedded hash-bearing data. It does not compare the
-- imported containing-body encoding. No ledger-state validation is implied.
data Body = Body
  { -- | Shared spending, output, validity, certificate, asset and governance fields.
    bodyFields :: !Fields,
    -- | Transaction fee in lovelace, from zero through 2^64 - 1.
    bodyFee :: !Word64,
    -- | Legacy genesis-authorized protocol parameter update proposal.
    bodyUpdate :: !(Maybe UpdateProposal),
    -- | Inputs reserved as script-failure collateral; absence differs from empty.
    bodyCollateral :: !(Maybe [Input]),
    -- | Optional output returning excess collateral on script failure.
    bodyCollateralReturn :: !(Maybe Output),
    -- | Total collateral claimed, in lovelace; absence differs from zero.
    bodyTotalCollateral :: !(Maybe Word64),
    -- | Dijkstra subtransactions in serialized order, each retaining its exact
    -- body, witnesses and auxiliary-data representation.
    bodySubTransactions :: !(Maybe [SubTransaction]),
    -- | Dijkstra requirements on initial account balances before this transaction.
    bodyStartingAccountBalanceIntervals :: !(Maybe (Entries RewardAddress BalanceInterval))
  }
  deriving (Eq, Show)

-- | Exact transaction-body bytes paired with semantic data. Equality compares
-- bytes, so alternative integer widths, tags and map order remain distinguishable.
data EncodedBody = EncodedBody !ByteString !Body !(Map.Map Word64 ByteString) deriving (Show)

instance Eq EncodedBody where
  left == right = toCbor left == toCbor right

-- | Set-valued fields in this body schema. Outputs and maps are not sets.
data SetField
  = -- | Spending inputs.
    Inputs
  | -- | Stake and governance certificates.
    Certificates
  | -- | Required signer or guard credentials.
    Guards
  | -- | Reference inputs.
    ReferenceInputs
  | -- | Governance proposals.
    Proposals
  | -- | Collateral inputs.
    CollateralInputs
  | -- | Included subtransactions; their internal encodings are unchanged.
    SubTransactions
  deriving (Eq, Ord, Show, Enum, Bounded)

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble required references, ordered outputs and fee with optional fields
-- absent. Empty input/output lists are representable but may fail ledger rules.
body :: [Input] -> [Output] -> Word64 -> Body
body inputs outputs amount = Body (Fields.fields inputs outputs) amount Nothing Nothing Nothing Nothing Nothing Nothing

-- | Fee measured in lovelace.
fee :: Body -> Word64
fee = bodyFee

-- | Set a fee in lovelace. Other semantic fields remain independent. Construct
-- a fresh 'EncodedBody' before signing this edited body.
setFee :: Word64 -> Body -> Body
setFee amount value = value {bodyFee = amount}

-- | Edit only a validated body's fee, retaining exact nested field bytes.
-- An unchanged fee returns the exact original body. A changed fee uses a fresh
-- definite outer map in numeric key order; other fields keep their original
-- encodings, including imported historical empty collections. The input snapshot
-- remains independent. Any signatures over the previous identifier need renewal.
setFeeEncoded :: Word64 -> EncodedBody -> EncodedBody
setFeeEncoded amount original@(EncodedBody _ semantic fields)
  | amount == fee semantic = original
  | otherwise = EncodedBody bytes (setFee amount semantic) updated
  where
    updated = Map.insert 2 (Cbor.encode (E.encodeWord64 amount)) fields
    bytes = Cbor.encode (E.encodeMapLen (fromIntegral (Map.size updated)) <> foldMap (\(key, payload) -> E.encodeWord64 key <> Cbor.raw payload) (Map.toAscList updated))

-- | Encode a fresh definite map in numeric field order, using shortest numbers
-- and tag 258 on sets. Present empty or duplicate guards return
-- 'InvalidTransactionField'. Embedded inline data and subtransactions retain exact
-- identity. Importing an existing signed body should use 'toCbor' instead.
encodeCbor :: Body -> Either Error ByteString
encodeCbor value = do
  Fields.validateFields False (bodyFields value)
  when (maybe False null (bodySubTransactions value)) (Left (InvalidTransactionField "Present subtransaction set must be nonempty"))
  Right (Cbor.encode (E.encodeMapLen (fromIntegral (length pairs)) <> foldMap (\(key, payload) -> E.encodeWord64 key <> payload) (sortOn fst pairs)))
  where
    pairs =
      Fields.encodeFields (bodyFields value)
        ++ [(2, E.encodeWord64 (bodyFee value))]
        ++ optional 6 (Cbor.raw . Updates.encodeProposal) (bodyUpdate value)
        ++ optional 13 inputSet (bodyCollateral value)
        ++ optional 16 (Cbor.raw . Output.encodeCbor) (bodyCollateralReturn value)
        ++ optional 17 E.encodeWord64 (bodyTotalCollateral value)
        ++ optional 23 subSet (bodySubTransactions value)
        ++ optional 27 Fields.encodeIntervals (bodyStartingAccountBalanceIntervals value)
    optional key encoder = maybe [] (\payload -> [(key, encoder payload)])
    inputSet values = E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Input.encodeCbor) (sort values)
    subSet values = E.encodeTag 258 <> E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . Sub.encodeCbor) values

-- | Validate fresh assembly and pair semantic data with its encoding. Present
-- empty guards or repeated guard credentials return 'InvalidTransactionField'.
fromBody :: Body -> Either Error EncodedBody
fromBody value = encodeCbor value >>= decodeCbor

-- | Inspect semantic fields without changing the original body bytes.
toBody :: EncodedBody -> Body
toBody (EncodedBody _ value _) = value

-- | Exact imported or freshly encoded ledger transaction-body bytes.
toCbor :: EncodedBody -> ByteString
toCbor (EncodedBody bytes _ _) = bytes

-- | Decode all pinned native body fields, including typed Dijkstra fields 23-27.
-- Unknown keys, repeated keys, missing inputs/outputs/fee, malformed nested data,
-- and trailing bytes return a structured error. Definite and indefinite maps,
-- nonminimal numbers and optional set tags retain their original byte identity.
decodeCbor :: ByteString -> Either Error EncodedBody
decodeCbor bytes = do
  fields <- Cbor.decode (Cbor.mapFields bytes) bytes
  unless (all (`elem` [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]) (Map.keys fields)) (Left (InvalidTransactionField "Unknown transaction body key"))
  common <- Fields.decodeFields fields
  amount <- required 2 (Cbor.decode D.decodeWord64) fields
  updates <- optional 6 (fmap Updates.toProposal . Updates.decodeProposal) fields
  collateral <- optional 13 inputDecoder fields
  collateralReturn <- optional 16 (fmap Output.toOutput . Output.decodeCbor) fields
  totalCollateral <- optional 17 (Cbor.decode D.decodeWord64) fields
  subs <- optional 23 subDecoder fields
  starting <- optional 27 Fields.decodeIntervals fields
  pure (EncodedBody bytes (Body common amount updates collateral collateralReturn totalCollateral subs starting) fields)
  where
    required key parser fields = maybe (Left (InvalidTransactionField "Missing fee")) parser (Map.lookup key fields)
    optional key parser fields = traverse parser (Map.lookup key fields)
    inputDecoder payload = sort <$> Cbor.decode (Cbor.setList (Cbor.nested payload Input.decodeCbor)) payload
    subDecoder payload = do
      values <- Cbor.decode (Cbor.setList (Cbor.nested payload Sub.decodeCbor)) payload
      when (null values) (Left (InvalidTransactionField "Present subtransaction set must be nonempty"))
      pure values

-- | Hash the exact body bytes with native BLAKE2b-256. This operation does not
-- normalize or rebuild the body. Native failures remain 'NativeError'.
hash :: EncodedBody -> IO (Either Error TransactionId)
hash value = do
  result <- Blake2b.compute 32 (toCbor value)
  pure (result >>= Id.fromBytes . Blake2b.toBytes)

-- | Encode fresh body fields with the requested set tags. Embedded values keep
-- their own encoding choices. Protocol validity is the caller's responsibility.
encodeCborWith :: SetEncoding -> Body -> Either Error ByteString
encodeCborWith requested value = do
  original <- fromBody value
  pure (toCbor (foldr (`withSetEncoding` requested) original [minBound .. maxBound]))

-- | Observe one field's set tag. An absent optional field returns 'Nothing'.
setEncoding :: SetField -> EncodedBody -> Maybe SetEncoding
setEncoding field (EncodedBody _ _ values) = SetEncoding.encoding <$> Map.lookup (setFieldKey field) values

-- | Whether the encoded spending-input collection carries set tag 258.
-- Other tagged collections do not affect this result; an absent input field
-- returns 'False'. This observes the exact body snapshot without re-encoding.
inputsAreTagged :: EncodedBody -> Bool
inputsAreTagged encoded = setEncoding Inputs encoded == Just TaggedSet

-- | Change one present field's set tag. Absence and an unchanged tag preserve
-- the exact original body. A change rebuilds the outer map in numeric key order,
-- retaining all other field bytes and the selected array's contents. It can
-- change the body hash: signatures over the previous body must be renewed.
withSetEncoding :: SetField -> SetEncoding -> EncodedBody -> EncodedBody
withSetEncoding field requested original@(EncodedBody _ semantic values)
  | updated == values = original
  | otherwise = EncodedBody encoded semantic updated
  where
    updated = Map.adjust (SetEncoding.withEncoding requested) (setFieldKey field) values
    encoded = Cbor.encode (E.encodeMapLen (fromIntegral (Map.size updated)) <> foldMap (\(key, payload) -> E.encodeWord64 key <> Cbor.raw payload) (Map.toAscList updated))

-- | Ledger map key of a supported set-valued field.
setFieldKey :: SetField -> Word64
setFieldKey field = case field of
  Inputs -> 0
  Certificates -> 4
  Guards -> 14
  ReferenceInputs -> 18
  Proposals -> 20
  CollateralInputs -> 13
  SubTransactions -> 23
