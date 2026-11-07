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
    requireGuard,
    guardWithRedeemer,
    directDeposit,
    accountBalance,
    startingAccountBalance,
    donate,
    propose,
    vote,
    voteWithRedeemer,
    voteWithDeferredRedeemer,
    attachSubTransaction,
    subTransactions,
    requireTopLevelGuard,
    validateTopLevel,
    reservedInputs,
    outerResolvedInputs,
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
import qualified Cometa.Certificate.Collection as Certificates
import Cometa.Credential (Credential, Guard, KeyHash, Payment, ScriptHash)
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import Cometa.Governance.Action (Action)
import qualified Cometa.Governance.Action as Action
import Cometa.Governance.ActionId (ActionId)
import qualified Cometa.Governance.ActionId as ActionId
import Cometa.Governance.Anchor (Anchor)
import qualified Cometa.Governance.Proposal as Proposal
import Cometa.Governance.Voting (Voter, VotingProcedure)
import qualified Cometa.Governance.Voting as Voting
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
import qualified Cometa.Script.Native as NativeScript
import qualified Cometa.Script.Plutus as Plutus
import Cometa.SubTransaction (SubTransaction)
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import Cometa.Transaction (Transaction)
import Cometa.Transaction.Fields (BalanceInterval (..))
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input
import Cometa.Transaction.Output (Output)
import qualified Cometa.Transaction.Output as Output
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.Value as Value
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.Maybe (catMaybes, fromMaybe)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
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
  | Guard (Credential Guard) (Maybe EncodedPlutusData)
  | DirectDeposit RewardAddress Word64
  | AccountBalance RewardAddress BalanceInterval
  | StartingBalance RewardAddress BalanceInterval
  | Donation Word64
  | Propose RewardAddress Action Anchor
  | Vote Voter ActionId VotingProcedure (Maybe Argument)
  | Sub SubTransaction [Utxo]
  | TopLevelGuard (Credential Guard) (Maybe EncodedPlutusData)
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

-- | Attach a native or Plutus script witness. Repeated attachments of the same
-- language and script bytes contribute one witness, ordered by the first
-- attachment. Different Plutus versions remain distinct.
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
  consistent "Conflicting required top-level guard arguments" [(g, r) | TopLevelGuard g r <- ops]
  consistent "Conflicting guard redeemers" [(g, r) | Guard g r <- ops]
  consistent "Conflicting account balance intervals" [(a, i) | AccountBalance a i <- ops]
  consistent "Conflicting starting account balance intervals" [(a, i) | StartingBalance a i <- ops]
  consistent "Conflicting votes for one action" [((v, a), p) | Vote v a p _ <- ops]
  consistent "Conflicting voter redeemers" [(v, r) | Vote v _ _ r <- ops]
  let donation = sum [toInteger n | Donation n <- ops]
      deposits = [(a, sum [toInteger n | DirectDeposit a' n <- ops, a == a']) | DirectDeposit a _ <- ops]
      subSpent = concatMap (Fields.fieldInputs . subFields . fst) (subTransactions (Plan instructions callbacks))
      outerSpent = [Utxo.input u | Spend u _ _ <- ops]
  unless (donation <= toInteger (maxBound :: Int64)) (Left (InvalidTransactionPlan "Combined donation exceeds signed native bounds"))
  when
    (any (\(_, n) -> n > toInteger (maxBound :: Int64)) deposits || any (\case DirectDeposit _ 0 -> True; _ -> False) ops)
    (Left (InvalidTransactionPlan "Direct deposits must be positive and fit signed native bounds"))
  unless
    (Set.size (Set.fromList subSpent) == length subSpent && all (`notElem` subSpent) outerSpent)
    (Left (InvalidTransactionPlan "Spending inputs overlap between transaction levels"))
  mapM_ validateSub (subTransactions (Plan instructions callbacks))
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
      normalizeMints (deduplicate [op | op <- original, case op of From _ -> False; Until _ -> False; Donation _ -> False; _ -> True])
        <> [Donation (fromInteger (sum ns)) | let ns = [toInteger n | Donation n <- original], not (null ns)]
        <> [From (maximum ns) | let ns = [n | From n <- original], not (null ns)]
        <> [Until (minimum ns) | let ns = [n | Until n <- original], not (null ns)]

    deduplicate [] = []
    deduplicate (op : rest) = op : deduplicate (if idempotent op then filter (not . sameAttachment op) rest else rest)
    -- Native builder_witnesses.c (eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1)
    -- appends scripts without enforcing witness-set uniqueness. Match the exact
    -- hash preimage here; Plutus outer bytestring framing is not script identity.
    sameAttachment (Script left) (Script right) = scriptIdentity left == scriptIdentity right
    sameAttachment left right = left == right
    scriptIdentity (Script.Native script) = (0, NativeScript.encodeCbor script)
    scriptIdentity (Script.Plutus script) = (fromEnum (Plutus.version script) + 1, Plutus.toBytes script)
    idempotent op = case op of
      Script {} -> True
      Spend {} -> True
      Reference {} -> True
      Metadata {} -> True
      Withdraw {} -> True
      Signer {} -> True
      Guard {} -> True
      TopLevelGuard {} -> True
      AccountBalance {} -> True
      StartingBalance {} -> True
      Vote {} -> True
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
    needs (Guard _ (Just _)) = True
    needs (Vote _ _ _ (Just _)) = True
    needs (Propose _ Action.ParameterChange {} _) = True
    needs (Propose _ Action.TreasuryWithdrawals {} _) = True
    needs (Sub transaction _) = not (null (Witnesses.redeemers (Witnesses.toWitnesses (Sub.witnesses transaction))))
    needs (Mint _ _ (Just _)) = True
    needs (Certificate _ (Just _)) = True
    needs (Withdraw _ _ (Just _)) = True
    needs _ = False

validitySlots :: Plan -> [Word64]
validitySlots (Plan instructions _) = concatMap slots (toList instructions)
  where
    slots (From n) = [n]
    slots (Until n) = [n]
    slots (Sub transaction _) =
      let fields = subFields transaction
       in catMaybes [Fields.fieldInvalidBefore fields, Fields.fieldInvalidAfter fields]
    slots _ = []

-- Native unique_signers does not inspect keys embedded in native scripts;
-- applications provide those additional witnesses through extraSigners.
witnessCount :: Plan -> Integer
witnessCount = sum . map count . normalizedOperations
  where
    count (Signer _) = 1
    count (Guard (Credential.KeyCredential _) _) = 1
    count Vote {} = 1
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
    source (Sub transaction resolved) =
      let fields = subFields transaction
          spent = Fields.fieldInputs fields
          funding = foldMap (Output.value . Utxo.output) [u | u <- resolved, Utxo.input u `elem` spent]
       in funding <> foldMap source (operationsFromFields fields)
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
    sink (DirectDeposit _ n) = Value.lovelace (toInteger n)
    sink (Donation n) = Value.lovelace (toInteger n)
    sink Propose {} = Value.lovelace (toInteger (fromMaybe 0 (Parameters.parameterGovernanceActionDeposit params)))
    sink (Sub transaction _) =
      let fields = subFields transaction
          deposits = sum [toInteger (Proposal.proposalDeposit proposal) | Just proposals <- [Fields.fieldProposalProcedures fields], proposal <- Proposal.toList proposals]
       in foldMap Output.value (Fields.fieldOutputs fields) <> Value.lovelace deposits <> foldMap sink (operationsFromFields fields)
    sink _ = mempty

resolvedInputs :: Plan -> [Utxo]
resolvedInputs (Plan instructions _) = concatMap resolved (toList instructions)
  where
    resolved (Spend u _ _) = [u]
    resolved (Reference u) = [u]
    resolved (Sub _ values) = values
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
  Guard credential redeemer -> fields 16 [bytes (credentialBytes credential), optional redeemer]
  DirectDeposit address amount -> fields 18 [bytes (Reward.toBytes address), E.encodeWord64 amount]
  AccountBalance address interval -> fields 19 [bytes (Reward.toBytes address), bytes (intervalBytes interval)]
  StartingBalance address interval -> fields 20 [bytes (Reward.toBytes address), bytes (intervalBytes interval)]
  Donation amount -> fields 21 [E.encodeWord64 amount]
  Propose address action anchor -> fields 22 [bytes (Proposal.encodeCbor (Proposal.Proposal 0 address action anchor))]
  Vote voter action procedure (Just (Deferred index)) -> fields 24 [bytes (Voting.encodeVoter voter), bytes (ActionId.encodeCbor action), bytes (Voting.encodeProcedure procedure), E.encodeInt index]
  Vote voter action procedure redeemer -> fields 23 [bytes (Voting.encodeVoter voter), bytes (ActionId.encodeCbor action), bytes (Voting.encodeProcedure procedure), argument redeemer]
  TopLevelGuard credential datum -> fields 26 [bytes (credentialBytes credential), optional datum]
  Sub transaction resolved -> fields 25 [bytes (Sub.encodeCbor transaction), E.encodeListLen (fromIntegral (length resolved)) <> foldMap (C.raw . Utxo.encodeCbor) resolved]
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
  Vote voter action procedure argument -> Vote voter action procedure (shift <$> argument)
  _ -> operation
  where
    shift (Deferred index) = Deferred (index + offset)
    shift argument = argument

-- | Require a key or script guard. Key guards require signatures; script guards
-- require a supplied script. Identical requirements are idempotent.
requireGuard :: Credential Guard -> Plan
requireGuard credential = one (Guard credential Nothing)

-- | Require a script guard with its guarding argument. Guard positions preserve
-- insertion order, including ordinary required signers. Supply a Plutus V4 script
-- for a top-level guard; attaching the script remains explicit.
guardWithRedeemer :: ScriptHash -> EncodedPlutusData -> Plan
guardWithRedeemer hash argument = one (Guard (Credential.ScriptCredential hash) (Just argument))

-- | Pay positive lovelace directly into a reward account. Repeated amounts add;
-- each amount and their total must fit the native signed 64-bit balance range.
directDeposit :: RewardAddress -> Word64 -> Plan
directDeposit account = one . DirectDeposit account

-- | Require the account balance when this transaction is applied. Identical
-- intervals compose idempotently; differing intervals fail at build time.
accountBalance :: RewardAddress -> BalanceInterval -> Plan
accountBalance account = one . AccountBalance account

-- | Require the account balance before any subtransaction of the batch applies.
startingAccountBalance :: RewardAddress -> BalanceInterval -> Plan
startingAccountBalance account = one . StartingBalance account

-- | Contribute lovelace to the treasury. Amounts add under composition, including
-- explicit zero; the total must fit the native signed 64-bit balance range.
donate :: Word64 -> Plan
donate = one . Donation

-- | Append a governance proposal. The configured protocol snapshot supplies its
-- deposit; the return account, action and anchor are supplied here. The native
-- parameter-change and treasury-withdrawal workflows require a guardrails
-- policy hash for an executable Plutus script. Those guardrails receive the
-- native unit argument @Constr 0 []@; no custom proposing argument is supplied.
propose :: RewardAddress -> Action -> Anchor -> Plan
propose address action = one . Propose address action

-- | Cast a key-authorized vote. Identical voter/action instructions are
-- idempotent; conflicting choices fail when building.
vote :: Voter -> ActionId -> VotingProcedure -> Plan
vote voter action procedure = one (Vote voter action procedure Nothing)

-- | Cast several votes authorized by one voter and one immediate argument.
-- A voter has one voting redeemer across all of its governance actions.
voteWithRedeemer :: Voter -> [(ActionId, VotingProcedure)] -> EncodedPlutusData -> Plan
voteWithRedeemer voter votes argument = foldMap (\(action, procedure) -> one (Vote voter action procedure (Just (Immediate argument)))) votes

-- | Cast several votes using one late argument for the voter. Empty groups do
-- not invoke the callback. Register each deferred voter once per plan.
voteWithDeferredRedeemer :: Voter -> [(ActionId, VotingProcedure)] -> DeferredRedeemer -> Plan
voteWithDeferredRedeemer voter votes callback =
  Plan (Seq.fromList [Vote voter action procedure (Just (Deferred 0)) | (action, procedure) <- votes]) (Seq.singleton callback)

-- | Carry an independently built subtransaction, retaining its exact bytes and
-- signatures. Supply every spending and reference input as a resolved snapshot.
-- Spending inputs of different transaction levels must be disjoint. The parent
-- funds the batch's net deficit and supplies the fee and collateral.
attachSubTransaction :: SubTransaction -> [Utxo] -> Plan
attachSubTransaction transaction = one . Sub transaction

subTransactions :: Plan -> [(SubTransaction, [Utxo])]
subTransactions (Plan operations _) = [(transaction, resolved) | Sub transaction resolved <- toList operations]

subFields :: SubTransaction -> Fields.Fields
subFields = SubBody.fields . SubBody.toBody . Sub.body

validateSub :: (SubTransaction, [Utxo]) -> Either Error ()
validateSub (transaction, resolved) = do
  let fields = subFields transaction
      expected = Fields.fieldInputs fields <> fromMaybe [] (Fields.fieldReferenceInputs fields)
      actual = map Utxo.input resolved
  unless (all (`elem` actual) expected) (Left (InvalidTransactionPlan "Unresolved subtransaction spending or reference input"))
  unless (Set.size (Set.fromList actual) == length actual) (Left (InvalidTransactionPlan "Duplicate subtransaction resolved input"))

operationsFromFields :: Fields.Fields -> [Operation]
operationsFromFields fields =
  map Pay (Fields.fieldOutputs fields)
    <> [Mint asset (fromInteger amount) Nothing | Just minted <- [Fields.fieldMint fields], (asset, amount) <- Value.toList (Fields.mintValue minted)]
    <> [Withdraw account amount Nothing | Just entries <- [Fields.fieldWithdrawals fields], (account, amount) <- Fields.entries entries]
    <> [Certificate cert Nothing | Just certificates <- [Fields.fieldCertificates fields], cert <- Certificates.toList certificates]
    <> [DirectDeposit account amount | Just entries <- [Fields.fieldDirectDeposits fields], (account, amount) <- Fields.entries entries]
    <> [Donation amount | Just amount <- [Fields.fieldDonation fields]]

credentialBytes :: Credential authority -> ByteString
credentialBytes credential =
  C.encode $
    E.encodeListLen 2 <> case credential of
      Credential.KeyCredential hash -> E.encodeWord 0 <> E.encodeBytes (Credential.keyHashBytes hash)
      Credential.ScriptCredential hash -> E.encodeWord 1 <> E.encodeBytes (Credential.scriptHashBytes hash)

intervalBytes :: BalanceInterval -> ByteString
intervalBytes interval = C.encode $ case interval of
  ExactBalance amount -> E.encodeWord64 amount
  BalanceRange lower upper -> E.encodeListLen 2 <> maybe E.encodeNull E.encodeWord64 lower <> maybe E.encodeNull E.encodeWord64 upper

requireTopLevelGuard :: Credential Guard -> Maybe EncodedPlutusData -> Plan
requireTopLevelGuard credential = one . TopLevelGuard credential

validateTopLevel :: Plan -> Either Error ()
validateTopLevel (Plan operations _) = unless (all permitted (toList operations)) (Left (InvalidTransactionPlan "Parent guard requirements belong to a subtransaction plan"))
  where
    permitted TopLevelGuard {} = False
    permitted _ = True

reservedInputs :: Plan -> [Cometa.Transaction.Input.Input]
reservedInputs plan = concatMap references (subTransactions plan)
  where
    references (transaction, _) = let fields = subFields transaction in Fields.fieldInputs fields <> fromMaybe [] (Fields.fieldReferenceInputs fields)

outerResolvedInputs :: Plan -> [Utxo]
outerResolvedInputs (Plan instructions _) = concatMap resolved (toList instructions)
  where
    resolved (Spend input _ _) = [input]
    resolved (Reference input) = [input]
    resolved _ = []
