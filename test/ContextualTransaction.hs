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
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module ContextualTransaction (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.Governance.ActionId as Action
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.ContextualTransaction as Internal
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as PlutusData
import qualified Cometa.PolicyId as Policy
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as NativeScript
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.SubTransaction.Indices as SubIndices
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Authority as Authority
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Indices as Indices
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Value
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import qualified Data.Set as Set
import Data.Word (Word64, Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Contextual transaction utilities"
    [ testCase "withdrawal, voter and redeemer ranks match native ledger order" lookupRanks,
      testCase "subtransaction primitive positions and empty collections" subPrimitives,
      testCase "certificate comparison uses native canonical data and exact rational components" certificates,
      testCase "top-level direct required keys exclude scripts and nested levels" authorities,
      testCase "invalid resolution and malformed transports are total on repeated calls" failures
    ]

key :: Word8 -> IO (Credential.KeyHash purpose)
key = require . Credential.keyHashFromBytes . B.replicate 28

script :: Word8 -> IO Credential.ScriptHash
script = require . Credential.scriptHashFromBytes . B.replicate 28

identifier :: Word8 -> IO TxId.TransactionId
identifier = require . TxId.fromBytes . B.replicate 32

rankFixture :: IO (Tx.Transaction, Sub.SubTransaction, [Reward.RewardAddress], [Voting.Voter])
rankFixture = do
  hash <- key 1
  scriptHash <- script 9
  alias <- require (Network.mkNetworkId 2)
  let rewards =
        [ Reward.fromCredential Network.testnet (Credential.KeyCredential hash),
          Reward.fromCredential Network.testnet (Credential.ScriptCredential scriptHash),
          Reward.fromCredential Network.mainnet (Credential.ScriptCredential scriptHash),
          Reward.fromCredential alias (Credential.KeyCredential hash)
        ]
  committee <- key 0
  drep <- key 1
  pool <- key 0
  let voters = [Voting.CommitteeVoter (Credential.KeyCredential committee), Voting.CommitteeVoter (Credential.ScriptCredential scriptHash), Voting.DRepVoter (Credential.KeyCredential drep), Voting.DRepVoter (Credential.ScriptCredential scriptHash), Voting.StakePoolVoter pool]
  txId <- identifier 0
  withdrawals <- require (Fields.mkEntries (zip rewards [1 ..]))
  votes <- require (Voting.fromList ([(voter, Action.ActionId txId 0, Voting.VotingProcedure Voting.Yes Nothing) | voter <- voters] ++ [(headVoter committee, Action.ActionId txId 1, Voting.VotingProcedure Voting.No Nothing)]))
  let fields = (Fields.fields [] []) {Fields.fieldWithdrawals = Just withdrawals, Fields.fieldVotingProcedures = Just votes}
      argument = PlutusData.fromData (PlutusData.Integer 0)
      redeemers = [Redeemer.Redeemer Redeemer.Voting 0 argument (ExUnits 0 0), Redeemer.Redeemer Redeemer.Spending 3 argument (ExUnits 0 0), Redeemer.Redeemer Redeemer.Spending 1 argument (ExUnits 0 0)]
  witnesses <- require (Witnesses.mkWitnesses [] [] [] [] redeemers)
  body <- require (Body.fromBody (Body.body [] [] 0) {Body.bodyFields = fields})
  subBody <- require (SubBody.fromBody (SubBody.fromFields fields))
  pure (Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing, Sub.assemble subBody (Witnesses.fromWitnesses witnesses) Nothing, rewards, voters)
  where
    headVoter = Voting.CommitteeVoter . Credential.KeyCredential

lookupRanks :: IO ()
lookupRanks = do
  (transaction, sub, rewards, voters) <- rankFixture
  forM_ (zip rewards [1, 0, 3, 1]) $ \(reward, expected) -> do
    Indices.findWithdrawal reward transaction @?= Just expected
    SubIndices.findWithdrawal reward sub @?= Just expected
    native transaction 0 (Reward.toBytes reward) 0 >>= (@?= Just expected)
  forM_ (zip voters [1, 0, 3, 2, 4]) $ \(voter, expected) -> do
    Indices.findVote voter transaction @?= Just expected
    SubIndices.findVote voter sub @?= Just expected
    native transaction 1 (Voting.encodeVoter voter) 0 >>= (@?= Just expected)
  forM_ [(Redeemer.Spending, 1, Just 0), (Redeemer.Spending, 3, Just 1), (Redeemer.Voting, 0, Just 2), (Redeemer.Guarding, 0, Nothing)] $ \(purpose, index, expected) -> do
    let target = Evaluation.RedeemerId purpose index
    Indices.findRedeemer target transaction @?= expected
    SubIndices.findRedeemer target sub @?= expected
    native transaction 2 (B.singleton (fromIntegral (fromEnum purpose))) (fromIntegral index) >>= (@?= expected)
  missing <- key 55
  Indices.findWithdrawal (Reward.fromCredential Network.mainnet (Credential.KeyCredential missing)) transaction @?= Nothing
  missingVoter <- key 55
  Indices.findVote (Voting.CommitteeVoter (Credential.KeyCredential missingVoter)) transaction @?= Nothing

subPrimitives :: IO ()
subPrimitives = do
  txId <- identifier 0
  policy <- require (Policy.fromBytes (B.replicate 28 4))
  destination <- require (Address.fromBytes (B.cons 0x60 (B.replicate 28 1)))
  output <- require (Output.mkOutput destination (Value.lovelace 5) Datum.NoDatum Nothing)
  mint <- require (Fields.mkMint (Value.singleton (AssetId.Native policy AssetName.empty) 1))
  let reference = Input.input txId 1
      fields = (Fields.fields [Input.input txId 9, reference] [output]) {Fields.fieldReferenceInputs = Just [reference], Fields.fieldMint = Just mint}
  body <- require (SubBody.fromBody (SubBody.fromFields fields))
  let sub = Sub.assemble body (Witnesses.fromWitnesses Witnesses.empty) Nothing
  SubIndices.findInput reference sub @?= Just 0
  SubIndices.findReferenceInput reference sub @?= Just 0
  SubIndices.findOutput destination 5 sub @?= Just 0
  SubIndices.findOutput destination 6 sub @?= Nothing
  SubIndices.findMintPolicy policy sub @?= Just 0
  cert <- key 1
  let certificate = Certificate.fromCertificate (Certificate.StakeDeregistration (Credential.KeyCredential cert))
  SubIndices.findCertificate certificate sub >>= (@?= Right Nothing)
  SubIndices.findWithdrawal (Reward.fromCredential Network.testnet (Credential.KeyCredential cert)) sub @?= Nothing
  SubIndices.findRedeemer (Evaluation.RedeemerId Redeemer.Spending 0) sub @?= Nothing

-- Native pool certificates retain numerator/denominator components, whereas
-- public semantic equality compares their rational value. Preserve this distinction.
poolCertificate :: Word64 -> Word64 -> ByteString
poolCertificate numerator denominator =
  Cbor.encode $
    E.encodeListLen 10
      <> E.encodeWord 3
      <> E.encodeBytes (B.replicate 28 1)
      <> E.encodeBytes (B.replicate 32 2)
      <> E.encodeWord 0
      <> E.encodeWord 0
      <> E.encodeTag 30
      <> E.encodeListLen 2
      <> E.encodeWord64 numerator
      <> E.encodeWord64 denominator
      <> E.encodeBytes (B.cons 0xe0 (B.replicate 28 3))
      <> E.encodeTag 258
      <> E.encodeListLen 0
      <> E.encodeListLen 0
      <> E.encodeNull

certificates :: IO ()
certificates = do
  certificate <- require (Certificate.decodeCbor (poolCertificate 2 4))
  reduced <- require (Certificate.decodeCbor (poolCertificate 1 2))
  Certificate.toCertificate certificate @?= Certificate.toCertificate reduced
  deregistration <- key 4
  let semantic = Certificate.StakeDeregistration (Credential.KeyCredential deregistration)
      canonical = Certificate.fromCertificate semantic
      nonminimal = B.pack [0x9f, 0x18, 1] <> B.drop 2 (Certificate.toCbor canonical) <> B.singleton 0xff
      candidates = Cbor.encode (E.encodeTag 258 <> E.encodeListLen 3 <> Cbor.raw (poolCertificate 2 4) <> Cbor.raw nonminimal <> Cbor.raw (Certificate.toCbor canonical))
      txBytes = Cbor.encode (E.encodeListLen 4 <> E.encodeMapLen 4 <> E.encodeWord 0 <> E.encodeListLen 0 <> E.encodeWord 1 <> E.encodeListLen 0 <> E.encodeWord 2 <> E.encodeWord 0 <> E.encodeWord 4 <> Cbor.raw candidates <> E.encodeMapLen 0 <> E.encodeBool True <> E.encodeNull)
  transaction <- require (Tx.decodeCbor txBytes)
  subBody <- require (SubBody.decodeCbor (Cbor.encode (E.encodeMapLen 3 <> E.encodeWord 0 <> E.encodeListLen 0 <> E.encodeWord 1 <> E.encodeListLen 0 <> E.encodeWord 4 <> Cbor.raw candidates)))
  let sub = Sub.assemble subBody (Tx.witnesses transaction) Nothing
  forM_ [(certificate, Just 0), (reduced, Nothing), (canonical, Just 1)] $ \(target, expected) -> do
    Indices.findCertificate target transaction >>= (@?= Right expected)
    SubIndices.findCertificate target sub >>= (@?= Right expected)
    native transaction 3 (Certificate.toCbor target) 0 >>= (@?= expected)
  Tx.encodeCbor transaction @?= txBytes

authorityFixture :: IO (Tx.Transaction, [Utxo.Utxo])
authorityFixture = do
  txId <- identifier 0
  payment <- require (Address.fromBytes (B.cons 0x60 (B.replicate 28 1)))
  collateral <- require (Address.fromBytes (B.cons 0x60 (B.replicate 28 2)))
  out <- require (Output.mkOutput payment (Value.lovelace 1) Datum.NoDatum Nothing)
  collateralOut <- require (Output.mkOutput collateral (Value.lovelace 1) Datum.NoDatum Nothing)
  guard <- key 3
  withdrawal <- key 4
  cert <- key 5
  voter <- key 6
  nativeKey <- key 7
  nested <- key 8
  scriptHash <- script 9
  withdrawals <- require (Fields.mkEntries [(Reward.fromCredential Network.testnet (Credential.KeyCredential withdrawal), 1)])
  votes <- require (Voting.fromList [(Voting.DRepVoter (Credential.KeyCredential voter), Action.ActionId txId 0, Voting.VotingProcedure Voting.Yes Nothing)])
  let input = Input.input txId 0
      collateralInput = Input.input txId 1
      referenceInput = Input.input txId 2
      fields = (Fields.fields [input] []) {Fields.fieldGuards = Just [Credential.KeyCredential guard, Credential.ScriptCredential scriptHash], Fields.fieldWithdrawals = Just withdrawals, Fields.fieldCertificates = Just (Certificates.fromList [Certificate.StakeDeregistration (Credential.KeyCredential cert)]), Fields.fieldVotingProcedures = Just votes, Fields.fieldReferenceInputs = Just [referenceInput]}
      subFields = (Fields.fields [] []) {Fields.fieldGuards = Just [Credential.KeyCredential nested]}
  subBody <- require (SubBody.fromBody (SubBody.fromFields subFields))
  let sub = Sub.assemble subBody (Witnesses.fromWitnesses Witnesses.empty) Nothing
  body <- require (Body.fromBody (Body.body [] [] 0) {Body.bodyFields = fields, Body.bodyCollateral = Just [collateralInput], Body.bodySubTransactions = Just [sub]})
  witnesses <- require (Witnesses.mkWitnesses [] [] [Script.Native (NativeScript.signature nativeKey)] [] [])
  pure (Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing, [Utxo.utxo input out, Utxo.utxo collateralInput collateralOut])

authorities :: IO ()
authorities = do
  (transaction, resolved) <- authorityFixture
  expected <- Set.fromList <$> traverse (require . Blake2b.fromBytes . B.replicate 28) [1 .. 6]
  actual <- Authority.requiredKeyHashes transaction resolved >>= require
  actual @?= expected
  assertBool "result hashes have 28 bytes" (all ((== 28) . B.length . Blake2b.toBytes) actual)
  replicateM_ 20 (Authority.requiredKeyHashes transaction resolved >>= (@?= Right expected))

failures :: IO ()
failures = do
  (transaction, resolved) <- authorityFixture
  Authority.requiredKeyHashes transaction [] >>= assertBool "missing spending/collateral resolution" . isLeft
  Authority.requiredKeyHashes transaction (resolved ++ resolved) >>= assertBool "duplicate resolution" . isLeft
  replicateM_ 20 $ do
    Internal.runRequiredKeys (B.singleton 0) (B.singleton 0x80) >>= assertBool "partial transaction parse" . isLeft
    Internal.runRequiredKeys (Tx.encodeCbor transaction) (B.pack [0x81, 0]) >>= assertBool "partial UTxO parse" . isLeft

require :: (Show error) => Either error value -> IO value
require = either (\failure -> assertFailure (show failure) >> fail "invalid fixture") pure

native :: Tx.Transaction -> CUInt -> ByteString -> Word64 -> IO (Maybe Word64)
native transaction operation keyBytes argument =
  B.useAsCStringLen (Tx.encodeCbor transaction) $ \(bytes, size) ->
    B.useAsCStringLen keyBytes $ \(keyData, keySize) -> alloca $ \result -> do
      status <- cIndex (castPtr bytes) (fromIntegral size) operation (castPtr keyData) (fromIntegral keySize) argument result
      if status == 0 then Just <$> peek result else (status @?= 9) >> pure Nothing

foreign import ccall unsafe "cometa_test_contextual_index"
  cIndex :: Ptr Word8 -> CSize -> CUInt -> Ptr Word8 -> CSize -> Word64 -> Ptr Word64 -> IO CUInt
