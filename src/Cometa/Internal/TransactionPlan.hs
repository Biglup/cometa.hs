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
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK hide #-}

-- | Owned composable builder instructions and preflight conflict checks.
module Cometa.Internal.TransactionPlan
  ( Plan,
    payTo,
    spend,
    spendWith,
    DeferredRedeemer,
    spendWithDeferredRedeemer,
    mintWithDeferredRedeemer,
    certificateWithDeferredRedeemer,
    withdrawWithDeferredRedeemer,
    deferredRedeemers,
    referenceInput,
    attachScript,
    mint,
    mintWithRedeemer,
    metadata,
    attachDatum,
    certificate,
    certificateWithRedeemer,
    withdraw,
    withdrawWithRedeemer,
    requireSigner,
    validFrom,
    validUntil,
    encodePlan,
    validatePlan,
    resolvedInputs,
    spendingInputs,
    planOutputs,
    sourceExtras,
    sinkExtras,
    validitySlots,
    witnessCount,
    requiresEvaluation,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import Cometa.Address.Reward (RewardAddress)
import qualified Cometa.Address.Reward as Reward
import Cometa.AssetId (AssetId (..))
import Cometa.AssetName (AssetName)
import qualified Cometa.AssetName as AssetName
import Cometa.Certificate (Certificate)
import qualified Cometa.Certificate as Certificate
import Cometa.Credential (KeyHash, Payment)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as C
import Cometa.Metadata (Metadatum)
import qualified Cometa.Metadata as Metadata
import Cometa.PlutusData (EncodedPlutusData)
import qualified Cometa.PlutusData as Data
import Cometa.PolicyId (PolicyId)
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.Parameters as Parameters
import Cometa.Script (Script)
import qualified Cometa.Script as Script
import Cometa.Transaction (Transaction)
import Cometa.Transaction.Output (Output)
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Foldable (toList)
import Data.Int (Int64)
import qualified Data.Sequence as Seq
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

-- | Compute an argument from the balanced draft and its selected spending inputs
-- in canonical order. The callback may run on every balancing iteration. It must
-- be pure and deterministic; return an explicit error to abort the build. Values
-- are ordinary owned snapshots and may be inspected without resource scopes.
type DeferredRedeemer = Transaction -> [Utxo] -> Either Error EncodedPlutusData

data Argument = Immediate EncodedPlutusData | Deferred Int deriving (Eq, Show)

data Operation
  = Pay Output
  | Spend Utxo (Maybe Argument) (Maybe EncodedPlutusData)
  | Reference Utxo
  | Script Script
  | Mint AssetId Int64 (Maybe Argument)
  | Metadata Word64 Metadatum
  | Datum EncodedPlutusData
  | Certificate Certificate (Maybe Argument)
  | Withdraw RewardAddress Word64 (Maybe Argument)
  | Signer (KeyHash Payment)
  | From Word64
  | Until Word64
  deriving (Eq, Show)

-- | Ordered immutable instructions. Composition preserves output order and
-- combines requirements; conflicts are reported by the single build boundary.
-- Function values have no structural equality or printable representation.
-- Plan intentionally has neither Eq nor Show; its monoid laws concern behavior.
data Plan = Plan (Seq.Seq Operation) (Seq.Seq DeferredRedeemer)

instance Semigroup Plan where
  Plan a callbacksA <> Plan b callbacksB =
    Plan (a <> fmap (shiftCallbacks (Seq.length callbacksA)) b) (callbacksA <> callbacksB)

instance Monoid Plan where
  mempty = Plan Seq.empty Seq.empty

-- DEFINITIONS ----------------------------------------------------------------

one :: Operation -> Plan
one op = Plan (Seq.singleton op) Seq.empty

-- | Append a payment output; minimum Ada is checked when building.
payTo :: Output -> Plan
payTo = one . Pay

-- | Spend a key-controlled resolved output without script arguments.
spend :: Utxo -> Plan
spend u = spendWith u Nothing Nothing

-- | Spend a resolved output with optional redeemer argument followed by optional
-- datum witness. Inline datums do not need a separate datum witness.
spendWith :: Utxo -> Maybe EncodedPlutusData -> Maybe EncodedPlutusData -> Plan
spendWith u r = one . Spend u (Immediate <$> r)

-- | Resolve a reference input without consuming its value.
referenceInput :: Utxo -> Plan
referenceInput = one . Reference

-- | Attach a native or Plutus script witness.
attachScript :: Script -> Plan
attachScript = one . Script

-- | Mint positive or burn negative token units under a native policy. Ada and
-- overflowing combined quantities are rejected when building.
mint :: AssetId -> Int64 -> Plan
mint a n = one (Mint a n Nothing)

-- | Mint or burn units under a Plutus policy using its redeemer argument.
mintWithRedeemer :: AssetId -> Int64 -> EncodedPlutusData -> Plan
mintWithRedeemer a n = one . Mint a n . Just . Immediate

-- | Require metadata under a label. Conflicting values fail when building.
metadata :: Word64 -> Metadatum -> Plan
metadata label = one . Metadata label

-- | Attach a datum witness.
attachDatum :: EncodedPlutusData -> Plan
attachDatum = one . Datum

-- | Append a certificate without a script argument.
certificate :: Certificate -> Plan
certificate c = one (Certificate c Nothing)

-- | Append a certificate authorized by the supplied Plutus argument.
certificateWithRedeemer :: Certificate -> EncodedPlutusData -> Plan
certificateWithRedeemer c = one . Certificate c . Just . Immediate

-- | Withdraw lovelace from a key-controlled reward account. Amounts above Int64
-- are rejected when building.
withdraw :: RewardAddress -> Word64 -> Plan
withdraw a n = one (Withdraw a n Nothing)

-- | Withdraw lovelace from a script reward account using its Plutus argument.
withdrawWithRedeemer :: RewardAddress -> Word64 -> EncodedPlutusData -> Plan
withdrawWithRedeemer a n = one . Withdraw a n . Just . Immediate

-- | Require a payment key hash to sign the completed transaction.
requireSigner :: KeyHash Payment -> Plan
requireSigner = one . Signer

-- | Inclusive lower validity slot. Composition takes the greatest lower bound.
validFrom :: Word64 -> Plan
validFrom = one . From

-- | Exclusive upper validity slot. Composition takes the least upper bound.
validUntil :: Word64 -> Plan
validUntil = one . Until

validatePlan :: Plan -> Either Error ()
validatePlan (Plan instructions callbacks) = do
  let ops = toList instructions
      inputs = [(Utxo.input u, (u, r, d)) | Spend u r d <- ops]
      refs = [(Utxo.input u, u) | Reference u <- ops]
      metas = [(k, v) | Metadata k v <- ops]
      withdrawals = [(a, (n, r)) | Withdraw a n r <- ops]
      certificates = [(c, r) | Certificate c r <- ops]
      mints = [(p, r) | Mint (Native p _) _ r <- ops]
      lows = [n | From n <- ops]
      highs = [n | Until n <- ops]
  consistent "Conflicting requirements for one spending input" inputs
  consistent "Conflicting reference input snapshots" refs
  consistent "Conflicting resolved input snapshots" [(Utxo.input u, u) | u <- resolvedInputs (Plan instructions callbacks)]
  consistent "Conflicting metadata label" metas
  consistent "Conflicting reward withdrawal" withdrawals
  consistent "Conflicting minting policy redeemers" mints
  consistent "Conflicting certificate redeemers" certificates
  let totals = [(asset, sum [toInteger amount | Mint asset' amount _ <- ops, asset == asset']) | Mint asset _ _ <- ops]
  when
    (any (\(_, amount) -> amount < toInteger (minBound :: Int64) || amount > toInteger (maxBound :: Int64)) totals)
    (Left (InvalidTransactionPlan "Combined mint quantity exceeds signed native bounds"))
  when (any isAdaMint ops) (Left (InvalidTransactionPlan "Ada cannot be minted"))
  when (any excessiveWithdrawal ops) (Left (InvalidTransactionPlan "Withdrawal exceeds signed native amount"))
  unless (null lows || null highs || maximum lows < minimum highs) (Left (InvalidTransactionPlan "Empty validity interval"))
  where
    consistent message pairs = unless (all (\(k, v) -> all (\(k', v') -> k /= k' || v == v') pairs) pairs) (Left (InvalidTransactionPlan message))
    isAdaMint (Mint Ada _ _) = True
    isAdaMint _ = False
    excessiveWithdrawal (Withdraw _ n _) = toInteger n > toInteger (maxBound :: Int64)
    excessiveWithdrawal _ = False

encodePlan :: Plan -> ByteString
encodePlan plan = C.encode (E.encodeListLen (fromIntegral (length ops)) <> foldMap encodeOperation ops)
  where
    ops = normalizedOperations plan

normalizedOperations :: Plan -> [Operation]
normalizedOperations (Plan instructions _) = ops
  where
    original = toList instructions
    ops =
      normalizeMints (deduplicate [op | op <- original, case op of From _ -> False; Until _ -> False; _ -> True])
        <> [From (maximum ns) | let ns = [n | From n <- original], not (null ns)]
        <> [Until (minimum ns) | let ns = [n | Until n <- original], not (null ns)]

    deduplicate [] = []
    deduplicate (op : rest) = op : deduplicate (if idempotent op then filter (/= op) rest else rest)
    idempotent op = case op of
      Spend {} -> True
      Reference {} -> True
      Metadata {} -> True
      Withdraw {} -> True
      Signer {} -> True
      _ -> False

    normalizeMints [] = []
    normalizeMints (Mint asset _ redeemer : rest) =
      let amount = sum [toInteger n | Mint a n _ <- original, a == asset]
          remaining = filter (\case Mint a _ _ -> a /= asset; _ -> True) rest
       in [Mint asset (fromInteger amount) redeemer | amount /= 0] <> normalizeMints remaining
    normalizeMints (op : rest) = op : normalizeMints rest

requiresEvaluation :: Plan -> Bool
requiresEvaluation = any needs . normalizedOperations
  where
    needs (Spend _ (Just _) _) = True
    needs (Mint _ _ (Just _)) = True
    needs (Certificate _ (Just _)) = True
    needs (Withdraw _ _ (Just _)) = True
    needs _ = False

validitySlots :: Plan -> [Word64]
validitySlots (Plan instructions _) = concatMap slots (toList instructions)
  where
    slots (From n) = [n]
    slots (Until n) = [n]
    slots _ = []

-- Native unique_signers does not inspect keys embedded in native scripts;
-- applications provide those additional witnesses through extraSigners.
witnessCount :: Plan -> Integer
witnessCount = sum . map count . normalizedOperations
  where
    count (Signer _) = 1
    count Withdraw {} = 1
    count (Certificate c _) = 1 + toInteger (B.length (Certificate.encodeCbor c)) `div` 28
    count _ = 0

spendingInputs :: Plan -> [Utxo]
spendingInputs (Plan instructions _) = [u | Spend u _ _ <- toList instructions]

planOutputs :: Plan -> [Output]
planOutputs (Plan instructions _) = [o | Pay o <- toList instructions]

sourceExtras :: Parameters.Parameters -> Plan -> Value.Value
sourceExtras params = foldMap source . normalizedOperations
  where
    source (Mint a n _) | n > 0 = Value.singleton a (toInteger n)
    source (Withdraw _ n _) = Value.lovelace (toInteger n)
    source (Certificate cert _) =
      Value.lovelace
        ( case cert of
            Certificate.StakeDeregistration _ -> toInteger (Parameters.parameterKeyDeposit params)
            Certificate.Unregistration _ amount -> toInteger amount
            Certificate.UnregisterDRep _ amount -> toInteger amount
            _ -> 0
        )
    source _ = mempty

sinkExtras :: Parameters.Parameters -> Plan -> Value.Value
sinkExtras params = foldMap sink . normalizedOperations
  where
    sink (Mint a n _) | n < 0 = Value.singleton a (negate (toInteger n))
    sink (Certificate cert _) =
      Value.lovelace
        ( case cert of
            Certificate.StakeRegistration _ -> toInteger (Parameters.parameterKeyDeposit params)
            Certificate.PoolRegistration _ -> toInteger (Parameters.parameterPoolDeposit params)
            Certificate.Registration _ amount -> toInteger amount
            Certificate.StakeRegistrationDelegation _ _ amount -> toInteger amount
            Certificate.VoteRegistrationDelegation _ _ amount -> toInteger amount
            Certificate.StakeVoteRegistrationDelegation _ _ _ amount -> toInteger amount
            Certificate.RegisterDRep _ amount _ -> toInteger amount
            _ -> 0
        )
    sink _ = mempty

resolvedInputs :: Plan -> [Utxo]
resolvedInputs (Plan instructions _) = concatMap resolved (toList instructions)
  where
    resolved (Spend u _ _) = [u]
    resolved (Reference u) = [u]
    resolved _ = []

encodeOperation :: Operation -> E.Encoding
encodeOperation operation = case operation of
  Pay o -> fields 0 [bytes (Output.encodeCbor o)]
  Spend u (Just (Deferred index)) d -> fields 12 [bytes (Utxo.encodeCbor u), E.encodeInt index, optional d]
  Spend u r d -> fields 1 [bytes (Utxo.encodeCbor u), argument r, optional d]
  Reference u -> fields 2 [bytes (Utxo.encodeCbor u)]
  Script s -> fields 3 [bytes (Script.encodeCbor s)]
  Mint Ada _ _ -> fields 4 []
  Mint (Native p n) amount (Just (Deferred index)) -> fields 13 [bytes (Policy.toBytes p), bytes (AssetName.toBytes n), E.encodeInt64 amount, E.encodeInt index]
  Mint (Native p n) amount r -> fields 4 [bytes (Policy.toBytes p), bytes (AssetName.toBytes n), E.encodeInt64 amount, argument r]
  Metadata label value -> fields 5 [E.encodeWord64 label, bytes (Metadata.encodeMetadatumCbor value)]
  Datum d -> fields 6 [bytes (Data.toCbor d)]
  Certificate c (Just (Deferred index)) -> fields 14 [bytes (Certificate.encodeCbor c), E.encodeInt index]
  Certificate c r -> fields 7 [bytes (Certificate.encodeCbor c), argument r]
  Withdraw a amount (Just (Deferred index)) -> fields 15 [bytes (Reward.toBytes a), E.encodeWord64 amount, E.encodeInt index]
  Withdraw a amount r -> fields 8 [bytes (Reward.toBytes a), E.encodeWord64 amount, argument r]
  Signer hash -> fields 9 [bytes (Credential.keyHashBytes hash)]
  From n -> fields 10 [E.encodeWord64 n]
  Until n -> fields 11 [E.encodeWord64 n]
  where
    fields tag xs = E.encodeListLen (fromIntegral (1 + length xs)) <> E.encodeWord tag <> mconcat xs
    bytes = E.encodeBytes
    argument Nothing = bytes mempty
    argument (Just (Immediate d)) = bytes (Data.toCbor d)
    argument (Just (Deferred index)) = E.encodeInt index
    optional = maybe (E.encodeBytes mempty) (bytes . Data.toCbor)

-- | Spend a resolved script output using a late argument and optional datum
-- witness. Register each spending input once when using a deferred argument.
spendWithDeferredRedeemer :: Utxo -> DeferredRedeemer -> Maybe EncodedPlutusData -> Plan
spendWithDeferredRedeemer u callback datum = deferred (Spend u (Just (Deferred 0)) datum) callback

-- | Mint or burn several assets under one policy using one late argument.
-- Quantities for repeated names are combined; zero totals are omitted. Empty
-- or entirely cancelled groups never call the callback. Register each policy
-- once; combining separate deferred groups for one policy fails at build.
mintWithDeferredRedeemer :: PolicyId -> [(AssetName, Int64)] -> DeferredRedeemer -> Plan
mintWithDeferredRedeemer policy assets callback =
  Plan
    (Seq.fromList [Mint (Native policy name) amount (Just (Deferred 0)) | (name, amount) <- assets])
    (Seq.singleton callback)

-- | Append a certificate authorized by a late Plutus argument.
certificateWithDeferredRedeemer :: Certificate -> DeferredRedeemer -> Plan
certificateWithDeferredRedeemer cert = deferred (Certificate cert (Just (Deferred 0)))

-- | Withdraw rewards using a late argument. Register each reward account once
-- when using a deferred argument.
withdrawWithDeferredRedeemer :: RewardAddress -> Word64 -> DeferredRedeemer -> Plan
withdrawWithDeferredRedeemer address amount = deferred (Withdraw address amount (Just (Deferred 0)))

deferred :: Operation -> DeferredRedeemer -> Plan
deferred operation callback = Plan (Seq.singleton operation) (Seq.singleton callback)

deferredRedeemers :: Plan -> Seq.Seq DeferredRedeemer
deferredRedeemers (Plan _ callbacks) = callbacks

shiftCallbacks :: Int -> Operation -> Operation
shiftCallbacks offset operation = case operation of
  Spend u argument datum -> Spend u (shift <$> argument) datum
  Mint asset amount argument -> Mint asset amount (shift <$> argument)
  Certificate cert argument -> Certificate cert (shift <$> argument)
  Withdraw address amount argument -> Withdraw address amount (shift <$> argument)
  _ -> operation
  where
    shift (Deferred index) = Deferred (index + offset)
    shift argument = argument
