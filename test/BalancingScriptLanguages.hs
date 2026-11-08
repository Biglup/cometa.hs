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

-- | Actual hash matching and purpose selection for outer language views.
module BalancingScriptLanguages (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (InvalidBuildingRequest))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Committee as Committee
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.BalancingScripts as Languages
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.NetworkId as Network
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.UnitInterval as Interval
import qualified Cometa.Value as Value
import Control.Monad (forM_)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Fixtures.ProtocolParameters as Fixture
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Balancing script language views"
    [ testCase "every certificate alternative uses its authorizing credential" certificates,
      testCase "governance, voters and guards select actual purposes" governance,
      testCase "original empty and zero mint policies still need scripts" mintPolicies,
      testCase "relevant references and nested witnesses supply outer purposes" sources,
      testCase "missing scripts, models and resolutions remain typed failures" missing
    ]

must :: (Show error) => Either error value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

key :: IO (Credential.KeyHash purpose)
key = must (Credential.keyHashFromBytes (B.replicate 28 7))

data Fixtures = Fixtures
  { parameters :: Parameters.Parameters,
    wanted :: Script.Script,
    unused :: Script.Script,
    wantedHash :: Credential.ScriptHash
  }

fixtures :: IO Fixtures
fixtures = do
  configured <- must Fixture.parameters
  requiredScript <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V2 (B.pack [1, 2]))
  unusedScript <- Script.Plutus <$> must (Plutus.fromBytes Plutus.V1 (B.pack [3, 4]))
  requiredHash <- Script.hash requiredScript >>= must
  models <- traverse (\language -> must (Models.mkCostModel language [1])) [0, 1, 255]
  pure (Fixtures (configured {Parameters.parameterCostModels = Just (Models.fromList models)}) requiredScript unusedScript requiredHash)

transaction :: Fields.Fields -> [Script.Script] -> [Sub.SubTransaction] -> IO Tx.Transaction
transaction fields scripts nested = do
  body <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = fields, Body.bodySubTransactions = if null nested then Nothing else Just nested}))
  witnesses <- must (Witnesses.mkWitnesses [] [] scripts [] [])
  pure (Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing)

check :: Fixtures -> [Utxo.Utxo] -> Tx.Transaction -> [Int] -> IO ()
check fixture resolved tx expected = do
  baseline <- Runtime.liveContexts
  result <- Languages.usedCostModels (parameters fixture) resolved tx >>= must
  map (fromIntegral . Models.languageId) (Models.toList result) @?= expected
  Runtime.liveContexts >>= (@?= baseline)

checkFields :: Fixtures -> Fields.Fields -> [Int] -> IO ()
checkFields fixture fields expected = do
  tx <- transaction fields [unused fixture, wanted fixture] []
  check fixture [] tx expected

certificates :: IO ()
certificates = do
  fixture <- fixtures
  stakeKey <- key
  poolKey <- key
  coldKey <- key
  hotKey <- key
  genesisKey <- key
  delegateKey <- key
  vrf <- must (Pool.vrfKeyHashFromBytes (B.replicate 32 8))
  margin <- must (Interval.mkUnitInterval 1 2)
  let credential :: Credential.Credential purpose
      credential = Credential.ScriptCredential (wantedHash fixture)
      account = Reward.fromCredential Network.testnet (Credential.KeyCredential stakeKey)
      pool = Pool.PoolParameters poolKey vrf Nothing 0 0 margin account Set.empty [] Nothing
      drep = DRep.DRepCredential credential
      cases =
        [ (Certificate.StakeRegistration credential, []),
          (Certificate.StakeDeregistration credential, [1]),
          (Certificate.StakeDelegation credential poolKey, [1]),
          (Certificate.PoolRegistration pool, []),
          (Certificate.PoolRetirement poolKey 0, []),
          (Certificate.GenesisKeyDelegation genesisKey delegateKey vrf, []),
          (Certificate.MoveInstantaneousRewards (Certificate.ToStakeCredentials Certificate.Reserves (Map.singleton credential 1)), []),
          (Certificate.Registration credential 0, [1]),
          (Certificate.Unregistration credential 0, [1]),
          (Certificate.VoteDelegation credential drep, [1]),
          (Certificate.StakeVoteDelegation credential poolKey drep, [1]),
          (Certificate.StakeRegistrationDelegation credential poolKey 0, [1]),
          (Certificate.VoteRegistrationDelegation credential drep 0, [1]),
          (Certificate.StakeVoteRegistrationDelegation credential poolKey drep 0, [1]),
          (Certificate.AuthorizeCommitteeHot credential (Credential.KeyCredential hotKey), [1]),
          (Certificate.ResignCommitteeCold credential Nothing, [1]),
          (Certificate.RegisterDRep credential 0 Nothing, [1]),
          (Certificate.UnregisterDRep credential 0, [1]),
          (Certificate.UpdateDRep credential Nothing, [1]),
          (Certificate.AuthorizeCommitteeHot (Credential.KeyCredential coldKey) credential, []),
          (Certificate.VoteDelegation (Credential.KeyCredential stakeKey) drep, [])
        ]
  forM_ cases $ \(certificate, expected) -> checkFields fixture ((Fields.fields [] []) {Fields.fieldCertificates = Just (Certificates.fromList [certificate])}) expected

governance :: IO ()
governance = do
  fixture <- fixtures
  stakeKey <- key
  drepKey <- key
  committeeKey <- key
  poolKey <- key
  url <- must (Anchor.mkUrl "https://example.com/anchor")
  digest <- must (Anchor.dataHashFromBytes (B.replicate 32 9))
  txid <- must (TxId.fromBytes (B.replicate 32 10))
  quorum <- must (Interval.mkUnitInterval 1 2)
  let account = Reward.fromCredential Network.testnet (Credential.KeyCredential stakeKey)
      scriptAccount = Reward.fromCredential Network.testnet (Credential.ScriptCredential (wantedHash fixture))
      anchor = Anchor.Anchor url digest
  withdrawals <- must (Action.withdrawalsFromList [(account, 0)])
  let actions =
        [ (Action.ParameterChange Nothing Update.empty (Just (wantedHash fixture)), [1]),
          (Action.ParameterChange Nothing Update.empty Nothing, []),
          (Action.HardForkInitiation Nothing (Version.ProtocolVersion 12 0), []),
          (Action.TreasuryWithdrawals withdrawals (Just (wantedHash fixture)), [1]),
          (Action.TreasuryWithdrawals withdrawals Nothing, []),
          (Action.NoConfidence Nothing, []),
          (Action.UpdateCommittee Nothing (Action.removalsFromList []) Committee.emptyMembers quorum, []),
          (Action.NewConstitution Nothing (Constitution.Constitution anchor (Just (wantedHash fixture))), []),
          (Action.InfoAction, [])
        ]
  forM_ actions $ \(action, expected) ->
    checkFields fixture ((Fields.fields [] []) {Fields.fieldProposalProcedures = Just (Proposal.fromList [Proposal.Proposal 0 account action anchor])}) expected
  let voters =
        [ (Voting.CommitteeVoter (Credential.ScriptCredential (wantedHash fixture)), [1]),
          (Voting.CommitteeVoter (Credential.KeyCredential committeeKey), []),
          (Voting.DRepVoter (Credential.ScriptCredential (wantedHash fixture)), [1]),
          (Voting.DRepVoter (Credential.KeyCredential drepKey), []),
          (Voting.StakePoolVoter poolKey, [])
        ]
  forM_ voters $ \(voter, expected) ->
    checkFields fixture ((Fields.fields [] []) {Fields.fieldVotingProcedures = Just (Voting.singleton voter (ActionId.ActionId txid 0) (Voting.VotingProcedure Voting.Yes Nothing))}) expected
  rewards <- must (Fields.mkEntries [(scriptAccount, 0)])
  checkFields fixture ((Fields.fields [] []) {Fields.fieldWithdrawals = Just rewards}) [1]
  checkFields fixture ((Fields.fields [] []) {Fields.fieldGuards = Just [Credential.ScriptCredential (wantedHash fixture)]}) [1]
  guardKey <- key
  checkFields fixture ((Fields.fields [] []) {Fields.fieldGuards = Just [Credential.KeyCredential guardKey]}) []
  accountGuards <- must (Fields.mkEntries [(Credential.ScriptCredential (wantedHash fixture), Nothing)])
  checkFields fixture ((Fields.fields [] []) {Fields.fieldRequiredTopLevelGuards = Just accountGuards}) []

mintPolicies :: IO ()
mintPolicies = do
  fixture <- fixtures
  forM_ [E.encodeMapLen 0, E.encodeMapLen 1 <> E.encodeBytes B.empty <> E.encodeWord 0] $ \assets -> do
    -- Import exact mint map keys instead of semantic Value (which erases zeros).
    let encoded = Cbor.encode (E.encodeMapLen 4 <> E.encodeWord 0 <> E.encodeListLen 0 <> E.encodeWord 1 <> E.encodeListLen 0 <> E.encodeWord 2 <> E.encodeWord 0 <> E.encodeWord 9 <> E.encodeMapLen 1 <> E.encodeBytes (Credential.scriptHashBytes (wantedHash fixture)) <> assets)
    body <- must (Body.decodeCbor encoded)
    witnesses <- must (Witnesses.mkWitnesses [] [] [unused fixture, wanted fixture] [] [])
    check fixture [] (Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing) [1]

sources :: IO ()
sources = do
  fixture <- fixtures
  txid <- must (TxId.fromBytes (B.replicate 32 11))
  paymentKey <- key
  let keyAddress = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential paymentKey))
      scriptAddress = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.ScriptCredential (wantedHash fixture)))
      spend = Input.input txid 0
      reference = Input.input txid 1
      nestedReference = Input.input txid 2
  locked <- must (Output.mkOutput scriptAddress (Value.lovelace 2000000) Datum.NoDatum Nothing)
  supplied <- must (Output.mkOutput keyAddress (Value.lovelace 2000000) Datum.NoDatum (Just (wanted fixture)))
  unusedScriptOutput <- must (Output.mkOutput keyAddress (Value.lovelace 2000000) Datum.NoDatum (Just (unused fixture)))
  let spent = Utxo.utxo spend locked
      ref = Utxo.utxo reference supplied
      nestedRef = Utxo.utxo nestedReference supplied
      fields = (Fields.fields [spend] []) {Fields.fieldReferenceInputs = Just [reference]}
  tx <- transaction fields [unused fixture] []
  check fixture [spent, ref] tx [1]
  -- A reference script on a spent output is also available.
  spentWithScript <- must (Output.mkOutput scriptAddress (Value.lovelace 2000000) Datum.NoDatum (Just (wanted fixture)))
  spendTx <- transaction (Fields.fields [spend] []) [unused fixture] []
  check fixture [Utxo.utxo spend spentWithScript] spendTx [1]
  -- A script in an unrelated resolved snapshot cannot satisfy a required hash.
  Languages.usedCostModels (parameters fixture) [spent, ref] spendTx >>= (@?= Left (InvalidBuildingRequest "A required body script is missing"))
  subBody <- must (SubBody.fromBody (SubBody.body [] []))
  subWitnesses <- must (Witnesses.mkWitnesses [] [] [wanted fixture] [] [])
  let nested = Sub.assemble subBody (Witnesses.fromWitnesses subWitnesses) Nothing
  nestedTx <- transaction (Fields.fields [spend] []) [unused fixture] [nested]
  check fixture [spent] nestedTx [1]
  nestedRefBody <- must (SubBody.fromBody (SubBody.fromFields ((Fields.fields [] []) {Fields.fieldReferenceInputs = Just [nestedReference]})))
  nestedRefTx <- transaction (Fields.fields [spend] []) [unused fixture] [Sub.fromBody nestedRefBody]
  check fixture [spent, nestedRef] nestedRefTx [1]
  -- A provided but unneeded reference language does not enter the language view.
  unusedRefTx <- transaction ((Fields.fields [spend] []) {Fields.fieldReferenceInputs = Just [reference]}) [wanted fixture] []
  check fixture [spent, Utxo.utxo reference unusedScriptOutput] unusedRefTx [1]
  nativeHash <- Script.hash (Script.Native (Native.invalidBefore 0)) >>= must
  nativeTx <- transaction ((Fields.fields [] []) {Fields.fieldGuards = Just [Credential.ScriptCredential nativeHash]}) [Script.Native (Native.invalidBefore 0), unused fixture] []
  check fixture [] nativeTx []

missing :: IO ()
missing = do
  fixture <- fixtures
  let fields = (Fields.fields [] []) {Fields.fieldGuards = Just [Credential.ScriptCredential (wantedHash fixture)]}
  absent <- transaction fields [unused fixture] []
  Languages.usedCostModels (parameters fixture) [] absent >>= (@?= Left (InvalidBuildingRequest "A required body script is missing"))
  tx <- transaction fields [wanted fixture] []
  Languages.usedCostModels ((parameters fixture) {Parameters.parameterCostModels = Just Models.empty}) [] tx >>= (@?= Left (InvalidBuildingRequest "A required script language has no cost model"))
  txid <- must (TxId.fromBytes (B.replicate 32 12))
  unresolved <- transaction (Fields.fields [Input.input txid 0] []) [] []
  Languages.usedCostModels (parameters fixture) [] unresolved >>= (@?= Left (InvalidBuildingRequest "A script-resolution input is missing"))
