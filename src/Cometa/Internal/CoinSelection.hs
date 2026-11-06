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

-- | Owned selection domains, contextual invariants and private wire encoding.
module Cometa.Internal.CoinSelection
  ( Selector (..),
    Strategy (..),
    largestFirst,
    randomImprove,
    randomImproveWithSeed,
    randomImproveWithOptions,
    SelectionOptions (..),
    SelectionRequest,
    Selection (..),
    mkSelectionRequest,
    preselected,
    available,
    target,
    outputHints,
    changeAddress,
    parameters,
    validateSelection,
    encodeRequest,
    decodeRequest,
    encodeSelection,
    decodeSelection,
    select,
    checkChange,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Address (Address)
import qualified Cometa.Address as Address
import Cometa.AssetId (AssetId (Ada))
import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.CoinSelection as Native
import qualified Cometa.Internal.ParameterSnapshot as Snapshot
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Internal.TransactionValue as V
import Cometa.Protocol.Parameters (Parameters)
import qualified Cometa.Protocol.Parameters as Parameters
import Cometa.Transaction.Datum (Datum (NoDatum))
import Cometa.Transaction.Input (Input)
import Cometa.Transaction.Output (Output)
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import Cometa.Value (Value)
import qualified Cometa.Value as Value
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (castPtr)
import Foreign.Storable (peek)

-- TYPES ----------------------------------------------------------------------

-- | Application-supplied coin selection. The function receives an immutable,
-- validated request and returns the complete selection, remaining candidates and
-- change. Use 'select' to check contextual laws and change minimum Ada. Exceptions
-- propagate normally; 'Left' represents an expected selection failure.
newtype Selector = Selector
  { -- | Select all spending inputs, including mandatory preselected inputs.
    selectCoins :: SelectionRequest -> IO (Either Error Selection)
  }

-- | Random-improve input selection policy. Both policies may acquire more Ada
-- to fund change. Neither policy changes the authoritative target.
data Strategy
  = -- | Select enough of each asset to meet its required quantity.
    Minimal
  | -- | Attempt approximately twice the required quantity to improve change.
    Optimal
  deriving (Eq, Ord, Show, Bounded, Enum)

-- | Select the largest available quantities of required assets, with Ada last.
-- Aggregate eligible and hinted quantities must fit signed 64-bit arithmetic;
-- excessive minimum-Ada multiplication bounds return 'InvalidSelectionRequest'.
-- Output hints are ignored. A successful selection always spends an input,
-- including when the target is zero. Insufficient funding or change Ada returns
-- the native balance failure. Change respects a supplied maximum value size;
-- absent or zero maximum value size disables splitting.
largestFirst :: Selector
largestFirst = nativeSelector 0 0 Optimal

-- | Round-robin random-improve with the 'Optimal' policy, seeded from the native
-- secure entropy source separately on every invocation. Aggregate bounds are
-- checked as for 'largestFirst'. Output hints influence
-- change shape, never the authoritative funding requirement.
randomImprove :: Selector
randomImprove = nativeSelector 1 0 Optimal

-- | Deterministic random-improve using 'Optimal'. The same seed and request
-- replay the same selection on each call; this is not a persistent random stream.
randomImproveWithSeed :: Word64 -> Selector
randomImproveWithSeed seed = randomImproveWithOptions seed Optimal

-- | Deterministic random-improve with an explicit seed and policy. Output hints
-- shape change; additional Ada inputs may be selected to satisfy minimum Ada.
-- Selection replays from the seed on each call. Deterministic replay applies to
-- the same library version; ordering can change between versions.
randomImproveWithOptions :: Word64 -> Strategy -> Selector
randomImproveWithOptions = nativeSelector 2

-- Native selectors use independent operation-local owners; no mutable handle or
-- RNG state escapes. Validate aggregate arithmetic before native signed sums.
nativeSelector :: Word64 -> Word64 -> Strategy -> Selector
nativeSelector algorithm seed strategy = Selector $ \request -> case validateNativeSelection request of
  Left failure -> pure (Left failure)
  Right () -> Runtime.withBytes (encodeRequest (disjointRequest request)) $ \bytes size -> do
    response <- Runtime.withOwnedBuffer "coinSelection.native" (Native.cNativeSelect (fromIntegral algorithm) seed (if strategy == Minimal then 0 else 1) bytes size)
    pure (response >>= decodeSelection)

-- Native random-improve concatenates mandatory and available pools without
-- deduplicating. P09 permits identical overlap, so marshal only optional
-- candidates; returned remaining is unchanged because mandatory is selected.
disjointRequest :: SelectionRequest -> SelectionRequest
disjointRequest request@(SelectionRequest options) = SelectionRequest options {selectionAvailable = filter (\item -> Map.notMember (Utxo.input item) mandatory) (available request)}
  where
    mandatory = Map.fromList [(Utxo.input item, ()) | item <- preselected request]

validateNativeSelection :: SelectionRequest -> Either Error ()
validateNativeSelection request = do
  let eligible = Map.elems (Map.fromList [(Utxo.input item, item) | item <- preselected request ++ available request])
      total = sumUtxos eligible
      capacity = total <> Value.fromList [(asset, negate amount) | (asset, amount) <- Value.toList (target request), amount < 0]
      hints = maybe mempty (foldMap Output.value) (outputHints request)
      maps = max 1 (maybe 0 length (outputHints request))
      assets = max 1 (length (filter ((/= Ada) . fst) (Value.toList capacity)))
      outputCount = toInteger maps * toInteger assets
      validate value = case V.validateOutput value of
        Left _ -> Left (InvalidSelectionRequest "Native selection aggregate quantities exceed int64")
        Right () -> Right ()
  validate total
  validate capacity
  validate hints
  -- The aggregate output bounds every possible split change output's encoded
  -- size. Bound all possible split maps as native largest-first accumulates their
  -- unsigned minimum Ada and casts that sum to int64. Include fixed overhead
  -- and worst coin-width growth, including shape-hinted empty maps.
  output <- Output.mkOutput (changeAddress request) capacity NoDatum Nothing
  case Parameters.parameterAdaPerUtxoByte (parameters request) of
    Just cost -> unless (toInteger cost * (toInteger (B.length (Output.encodeCbor output)) + 168) * outputCount <= toInteger (maxBound :: Int64)) (Left (InvalidSelectionRequest "Native change minimum Ada arithmetic exceeds int64"))
    Nothing -> Left (InvalidSelectionRequest "Ada per UTxO byte is required")

-- | Named input to request validation. Candidate lists must have unique
-- references. Identical references may occur once in both lists; conflicting
-- resolved outputs are rejected. Preselected inputs may be outside available.
data SelectionOptions = SelectionOptions
  { -- | Mandatory selected inputs. Each must survive in a successful selection.
    selectionPreselected :: ![Utxo],
    -- | Eligible candidate inputs, including any optional overlap with preselected.
    selectionAvailable :: ![Utxo],
    -- | Authoritative signed value to fund, including externally assessed fees,
    -- deposits, withdrawals and mint. Negative components are implicit surplus
    -- that must return as change. Ada counts lovelace; quantities fit Int64.
    selectionTarget :: !Value,
    -- | Optional output-shape hints, independent of authoritative target arithmetic.
    selectionOutputHints :: !(Maybe [Output]),
    -- | Required destination for every generated change output.
    selectionChangeAddress :: !Address,
    -- | Current protocol snapshot. Ada-per-UTxO-byte must be present for change
    -- minimum-Ada validation. This does not promise consistent chain observations.
    selectionParameters :: !Parameters
  }
  deriving (Eq, Show)

-- | Validated request. Equality compares all owned fields and preserves list
-- order; validation does not select coins or access chain state.
newtype SelectionRequest = SelectionRequest SelectionOptions deriving (Eq, Show)

-- | Full selection result. Assembly is total; 'select' checks contextual
-- eligibility, balance, remaining candidates, change destination and minimum Ada.
-- Equality compares list order and semantic fields; no random-choice equivalence
-- is implied. Empty change means an exact target match.
data Selection = Selection
  { -- | Complete selected inputs, including the preselected inputs, with unique refs.
    selected :: ![Utxo],
    -- | Exactly the available candidates not selected, with unique references.
    remaining :: ![Utxo],
    -- | Locally balanced outputs returning all excess value to the change address.
    change :: ![Output]
  }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate unique references and nonconflicting overlapping snapshots, a
-- signed native-range target, an available Ada-per-UTxO-byte parameter,
-- and supported parameter bounds. Failure returns 'InvalidSelectionRequest' or
-- 'InvalidParameterSnapshot'. This does not query input eligibility on chain.
mkSelectionRequest :: SelectionOptions -> Either Error SelectionRequest
mkSelectionRequest options = do
  mandatory <- indexUtxos (InvalidSelectionRequest "Duplicate preselected reference") (selectionPreselected options)
  candidates <- indexUtxos (InvalidSelectionRequest "Duplicate available reference") (selectionAvailable options)
  unless (and (Map.elems (Map.intersectionWith (==) mandatory candidates))) (Left (InvalidSelectionRequest "Conflicting overlapping UTxO snapshots"))
  unless
    (all (\(_, quantity) -> quantity >= toInteger (minBound :: Int64) && quantity <= toInteger (maxBound :: Int64)) (Value.toList (selectionTarget options)))
    (Left (InvalidSelectionRequest "Target quantities must fit int64"))
  case Parameters.parameterAdaPerUtxoByte (selectionParameters options) of
    Nothing -> Left (InvalidSelectionRequest "Ada per UTxO byte is required")
    Just _ -> pure ()
  Snapshot.validateNative (selectionParameters options)
  pure (SelectionRequest options)

-- | Mandatory input snapshots in caller order.
preselected :: SelectionRequest -> [Utxo]
preselected (SelectionRequest options) = selectionPreselected options

-- | Eligible candidate snapshots in caller order.
available :: SelectionRequest -> [Utxo]
available (SelectionRequest options) = selectionAvailable options

-- | Authoritative funding requirement; output hints do not change it.
target :: SelectionRequest -> Value
target (SelectionRequest options) = selectionTarget options

-- | Optional output-shape hints, retaining absence versus an empty hint list.
outputHints :: SelectionRequest -> Maybe [Output]
outputHints (SelectionRequest options) = selectionOutputHints options

-- | Destination required for each change output.
changeAddress :: SelectionRequest -> Address
changeAddress (SelectionRequest options) = selectionChangeAddress options

-- | Protocol snapshot supplied with the request.
parameters :: SelectionRequest -> Parameters
parameters (SelectionRequest options) = selectionParameters options

-- | Check unique references, unaltered eligible snapshots, mandatory inclusion,
-- exact remaining accounting and componentwise selected = target + change.
-- Change destinations must match. Ordering does not affect these laws. This
-- pure check does not assess minimum Ada; 'select' performs that additional check.
validateSelection :: SelectionRequest -> Selection -> Either Error ()
validateSelection request result = do
  chosen <- indexUtxos (InvalidSelection "Repeated selected reference") (selected result)
  rest <- indexUtxos (InvalidSelection "Repeated remaining reference") (remaining result)
  let mandatory = Map.fromList [(Utxo.input value, value) | value <- preselected request]
      candidates = Map.fromList [(Utxo.input value, value) | value <- available request]
      eligible = Map.union mandatory candidates
  unless (Map.isSubmapOfBy (==) chosen eligible) (Left (InvalidSelection "Selection contains an ineligible or changed snapshot"))
  unless (Map.isSubmapOfBy (==) mandatory chosen) (Left (InvalidSelection "Preselected input was dropped or changed"))
  unless (rest == Map.difference candidates chosen) (Left (InvalidSelection "Remaining candidates do not account exactly for the available set"))
  unless (all ((== changeAddress request) . Output.address) (change result)) (Left (InvalidSelection "Change destination differs from request"))
  unless (sumUtxos (selected result) == target request <> foldMap Output.value (change result)) (Left (InvalidSelection "Selected value differs from target plus change"))

indexUtxos :: Error -> [Utxo] -> Either Error (Map Input Utxo)
indexUtxos failure values = do
  let result = Map.fromList [(Utxo.input value, value) | value <- values]
  unless (Map.size result == length values) (Left failure)
  pure result

sumUtxos :: [Utxo] -> Value
sumUtxos = foldMap (Output.value . Utxo.output)

-- | Invoke an application selector once, validate its complete result and check
-- minimum Ada for every change output. No fees, additional inputs, witnesses or
-- output amounts are changed implicitly. Expected failures retain their error;
-- callback exceptions and asynchronous cancellation propagate normally.
select :: Selector -> SelectionRequest -> IO (Either Error Selection)
select selector request = do
  result <- selectCoins selector request
  case result >>= (\selection -> validateSelection request selection >> pure selection) of
    Left failure -> pure (Left failure)
    Right selection -> do
      checked <- checkChange request (change selection)
      pure (selection <$ checked)

checkChange :: SelectionRequest -> [Output] -> IO (Either Error ())
checkChange request outputs = case Parameters.parameterAdaPerUtxoByte (parameters request) of
  Nothing -> pure (Left (InvalidSelectionRequest "Ada per UTxO byte is required"))
  Just cost -> go cost outputs
  where
    go _ [] = pure (Right ())
    go cost (output : rest) = do
      required <- minimumAda cost output
      case required of
        Left failure -> pure (Left failure)
        Right amount
          | Value.quantity Ada (Output.value output) < toInteger amount -> pure (Left (InvalidSelection "Change output is below minimum Ada"))
          | otherwise -> go cost rest

minimumAda :: Word64 -> Output -> IO (Either Error Word64)
minimumAda cost output = B.useAsCStringLen (Output.encodeCbor output) $ \(bytes, size) -> alloca $ \result -> do
  code <- Native.cMinimumAda (castPtr bytes) (fromIntegral size) cost result
  status <- Runtime.checkStatus "coinSelection.minimumAda" code
  case status of
    Left failure -> pure (Left failure)
    Right () -> Right <$> peek result

encodeList :: (a -> ByteString) -> [a] -> E.Encoding
encodeList encode values = E.encodeListLen (fromIntegral (length values)) <> foldMap (Cbor.raw . encode) values

-- Internal requests use signed coin plus signed native-asset quantities.
-- Ledger Value CBOR cannot represent negative coin, despite native value_t
-- supporting signed arithmetic for implicit sources during balancing.
encodeValue :: Value -> E.Encoding
encodeValue value = E.encodeListLen 2 <> E.encodeInteger (Value.quantity Ada value) <> V.encodeAssets value

decodeValue :: D.Decoder s Value
decodeValue = Cbor.array 2 (((<>) . Value.lovelace <$> D.decodeInteger) <*> V.decodeAssets)

encodeRequest :: SelectionRequest -> ByteString
encodeRequest request = Cbor.encode (E.encodeListLen 6 <> encodeList Utxo.encodeCbor (preselected request) <> encodeList Utxo.encodeCbor (available request) <> encodeValue (target request) <> maybe E.encodeNull (encodeList Output.encodeCbor) (outputHints request) <> E.encodeBytes (Address.toBytes (changeAddress request)) <> Cbor.raw (Snapshot.encodeSnapshot (parameters request)))

decodeRequest :: ByteString -> Either Error SelectionRequest
decodeRequest bytes = Cbor.decode parser bytes >>= mkSelectionRequest
  where
    parser =
      Cbor.array
        6
        ( SelectionOptions
            <$> Cbor.list (Cbor.nested bytes Utxo.decodeCbor)
            <*> Cbor.list (Cbor.nested bytes Utxo.decodeCbor)
            <*> decodeValue
            <*> Cbor.optional (Cbor.list (Output.toOutput <$> Cbor.nested bytes Output.decodeCbor))
            <*> (D.decodeBytes >>= either (fail . show) pure . Address.fromBytes)
            <*> Cbor.nested bytes Snapshot.decodeSnapshot
        )

encodeSelection :: Selection -> ByteString
encodeSelection result = Cbor.encode (E.encodeListLen 3 <> encodeList Utxo.encodeCbor (selected result) <> encodeList Utxo.encodeCbor (remaining result) <> encodeList Output.encodeCbor (change result))

decodeSelection :: ByteString -> Either Error Selection
decodeSelection bytes = Cbor.decode (Cbor.array 3 (Selection <$> Cbor.list (Cbor.nested bytes Utxo.decodeCbor) <*> Cbor.list (Cbor.nested bytes Utxo.decodeCbor) <*> Cbor.list (Output.toOutput <$> Cbor.nested bytes Output.decodeCbor))) bytes
