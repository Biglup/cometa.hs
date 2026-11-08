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

-- | Complete pinned transaction JSON fixtures and fresh-owner failure paths.
module TransactionInspection (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as Encoding
import qualified Codec.CBOR.Write as Write
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Committee as Committee
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Inspection as Standalone
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.Internal.Inspection as Internal
import qualified Cometa.Metadata as Metadata
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as PolicyId
import qualified Cometa.Pool.Metadata as PoolMetadata
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Pool.Relay as Relay
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.DRepVotingThresholds as DRepThresholds
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as ExUnits
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Cometa.Protocol.PoolVotingThresholds as PoolThresholds
import qualified Cometa.Protocol.ProposedUpdates as Proposed
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Inspection as Inspection
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.UnitInterval as Unit
import qualified Cometa.Value as Coin
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, evaluate, throwIO)
import Control.Monad (forM, forM_, replicateM, replicateM_, (>=>))
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Fixtures.Inspection as Fixture
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Transaction JSON inspection"
    [ testCase "protocol collections and Dijkstra standalone schemas match parent fields" standaloneCollections,
      testCase "standalone leaf schemas, optional fields and native lifetime boundaries" standaloneLeaves,
      testCase "standalone leaf inspectors reject complete schema-invalid CBOR" standaloneLeafFailures,
      testCase "standalone values match typed fields of pinned transaction JSON" standaloneCorpus,
      testCase "standalone governance, certificates, pools and protocol fields" standaloneDomains,
      testCase "complete pinned Conway/Dijkstra and native rich JSON matches" corpus,
      testCase "inspection leaves exact bytes, transaction IDs and signatures unchanged" identities,
      testCase "arbitrary integers and binary data retain their JSON meaning" largeValues,
      testCase "malformed, truncated and trailing CBOR fail on every native entrypoint" failures,
      testCase "repeated calls and returned JSON outlive cleanup and collection" repeated,
      testCase "independent concurrent inspections return complete snapshots" concurrent
    ]

must :: (Show error) => Either error value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

load :: Fixture.Fixture -> IO (Tx.Transaction, Value)
load fixture = do
  bytes <- maybe (assertFailure "Invalid fixture hexadecimal" >> fail "fixture") pure (Hex.decodeHex (Fixture.fixtureCbor fixture))
  transaction <- must (Tx.decodeCbor bytes)
  expected <- must (eitherDecodeStrict' (Fixture.fixtureJson fixture))
  pure (transaction, expected)

field :: Key -> Value -> IO Value
field key (Object values) = maybe (assertFailure "Missing expected JSON field" >> fail "fixture") pure (KeyMap.lookup key values)
field _ _ = assertFailure "Expected JSON object" >> fail "fixture"

corpus :: IO ()
corpus = forM_ Fixture.fixtures $ \fixture -> do
  (transaction, expected) <- load fixture
  Inspection.transaction transaction >>= (@?= Right expected)
  expectedBody <- field "body" expected
  Inspection.body (Tx.body transaction) >>= (@?= Right expectedBody)
  let subs = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
  expectedSubs <- case expectedBody of
    Object values -> case KeyMap.lookup "sub_transactions" values of
      Nothing -> pure []
      Just (Array values') -> pure (toList values')
      _ -> assertFailure "Invalid expected subtransaction array" >> fail "fixture"
    _ -> assertFailure "Invalid expected body" >> fail "fixture"
  length subs @?= length expectedSubs
  forM_ (zip subs expectedSubs) $ \(sub, json) -> do
    Inspection.subTransaction sub >>= (@?= Right json)
    expectedSubBody <- field "body" json
    Inspection.subBody (Sub.body sub) >>= (@?= Right expectedSubBody)
    case json of
      Object values -> do
        assertBool "subtransaction acquired a validity flag" (not (KeyMap.member "is_valid" values))
        case expectedSubBody of
          Object fields -> assertBool "subtransaction acquired a fee" (not (KeyMap.member "fee" fields))
          _ -> assertFailure "Invalid expected subtransaction body"
      _ -> assertFailure "Invalid expected subtransaction"

identities :: IO ()
identities = forM_ Fixture.fixtures $ \fixture -> do
  (transaction, _) <- load fixture
  let original = Tx.encodeCbor transaction
      witnessBytes = Witnesses.toCbor (Tx.witnesses transaction)
      subs = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
      subBytes = map Sub.encodeCbor subs
  originalId <- Tx.transactionId transaction
  _ <- Inspection.transaction transaction >>= must
  mapM_ (Inspection.subTransaction >=> must) subs
  Tx.encodeCbor transaction @?= original
  Witnesses.toCbor (Tx.witnesses transaction) @?= witnessBytes
  Tx.transactionId transaction >>= (@?= originalId)
  map Sub.encodeCbor subs @?= subBytes

largeValues :: IO ()
largeValues = do
  let huge = 2 ^ (160 :: Int) + 3
      datum = Data.fromData (Data.List [Data.Integer huge, Data.Integer (negate huge), Data.Bytes (B.pack [0, 255, 128, 0])])
      expectedDatum =
        object
          [ "tag" .= ("list" :: Text.Text),
            "contents"
              .= [ object ["tag" .= ("integer" :: Text.Text), "value" .= Text.pack (show huge)],
                   object ["tag" .= ("integer" :: Text.Text), "value" .= Text.pack (show (negate huge))],
                   object ["tag" .= ("bytes" :: Text.Text), "value" .= ("00ff8000" :: Text.Text)]
                 ]
          ]
  body <- must (Body.fromBody (Body.body [] [] maxBound))
  witnesses <- must (Witnesses.mkWitnesses [] [] [] [datum] [])
  let transaction = Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing
      expected = object ["body" .= object ["inputs" .= ([] :: [Value]), "outputs" .= ([] :: [Value]), "fee" .= ("18446744073709551615" :: Text.Text)], "is_valid" .= True, "witness_set" .= object ["plutus_data" .= [expectedDatum]]]
  Inspection.transaction transaction >>= (@?= Right expected)
  Standalone.plutusData datum >>= (@?= Right expectedDatum)

failures :: IO ()
failures = do
  let invalid = [B.empty, B.singleton 0xff, B.singleton 0xa1, B.singleton 0xf6]
  replicateM_ 25 $ forM_ [0 .. 25] $ \kind -> forM_ invalid (Internal.runUnchecked kind >=> (assertBool "Malformed CBOR inspection succeeded" . isLeft))
  forM_ Fixture.fixtures $ \fixture -> do
    (transaction, _) <- load fixture
    Internal.runUnchecked 0 (Tx.encodeCbor transaction <> B.singleton 0) >>= assertBool "Trailing transaction bytes accepted" . isLeft
    Internal.runUnchecked 2 (Body.toCbor (Tx.body transaction) <> B.singleton 0) >>= assertBool "Trailing body bytes accepted" . isLeft
    forM_ (fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))) $ \sub -> do
      Internal.runUnchecked 1 (Sub.encodeCbor sub <> B.singleton 0) >>= assertBool "Trailing subtransaction bytes accepted" . isLeft
      Internal.runUnchecked 3 (SubBody.toCbor (Sub.body sub) <> B.singleton 0) >>= assertBool "Trailing sub-body bytes accepted" . isLeft
  Internal.runUnchecked 99 B.empty >>= assertBool "Unknown native inspection operation succeeded" . isLeft
  assertBool "Invalid CBOR constructed a public transaction" (isLeft (Tx.decodeCbor (B.singleton 0xff)))

repeated :: IO ()
repeated = forM_ Fixture.fixtures $ \fixture -> do
  (transaction, expected) <- load fixture
  values <- replicateM 20 (Inspection.transaction transaction >>= must)
  performGC
  map encode values @?= replicate 20 (encode expected)

concurrent :: IO ()
concurrent = do
  fixtures <- traverse load Fixture.fixtures
  completions <- forM fixtures $ \(transaction, expected) -> do
    finished <- newEmptyMVar
    _ <-
      forkFinally
        ( do
            Inspection.transaction transaction >>= (@?= Right expected)
            expectedWitnesses <- field "witness_set" expected
            Standalone.witnesses (Tx.witnesses transaction) >>= (@?= Right expectedWitnesses)
        )
        (putMVar finished)
    pure finished
  forM_ completions $ \finished -> do
    outcome <- takeMVar finished
    either (throwIO :: SomeException -> IO ()) pure outcome

optionalArray :: Key -> Value -> IO [Value]
optionalArray key (Object fields) = case KeyMap.lookup key fields of
  Nothing -> pure []
  Just (Array values) -> pure (toList values)
  _ -> assertFailure "Expected JSON array" >> fail "fixture"
optionalArray _ _ = assertFailure "Expected JSON object" >> fail "fixture"

standaloneCorpus :: IO ()
standaloneCorpus = forM_ Fixture.fixtures $ \fixture -> do
  (transaction, expected) <- load fixture
  expectedBody <- field "body" expected
  expectedWitnesses <- field "witness_set" expected
  inspectFields (Body.bodyFields (Body.toBody (Tx.body transaction))) (Tx.witnesses transaction) expectedBody expectedWitnesses
  forM_ (Tx.auxiliaryData transaction) $ \aux -> do
    json <- field "auxiliary_data" expected
    inspectAuxiliary aux json
  let subs = fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body transaction)))
  expectedSubs <- optionalArray "sub_transactions" expectedBody
  forM_ (zip subs expectedSubs) $ \(sub, json) -> do
    subBody <- field "body" json
    subWitnesses <- field "witness_set" json
    inspectFields (SubBody.fields (SubBody.toBody (Sub.body sub))) (Sub.witnesses sub) subBody subWitnesses
    forM_ (Sub.auxiliaryData sub) $ \aux -> field "auxiliary_data" json >>= inspectAuxiliary aux
  where
    inspectAuxiliary auxiliary json = do
      Standalone.auxiliaryData auxiliary >>= (@?= Right json)
      forM_ (Auxiliary.metadata (Auxiliary.toAuxiliaryData auxiliary)) $ \encoded -> do
        expectedMetadata <- field "metadata" json
        let metadata = Metadata.toMetadata encoded
        Standalone.metadata metadata >>= (@?= Right expectedMetadata)
        entries <- case expectedMetadata of
          Array items -> pure (toList items)
          _ -> assertFailure "Expected metadata entries" >> fail "fixture"
        forM_ (zip (Metadata.toList metadata) entries) $ \((_, metadatum), entry) ->
          field "value" entry >>= \expectedValue -> Standalone.metadatum metadatum >>= (@?= Right expectedValue)
    inspectFields fields witnesses bodyJson witnessJson = do
      Standalone.witnesses witnesses >>= (@?= Right witnessJson)
      inputs <- optionalArray "inputs" bodyJson
      forM_ (zip (Fields.fieldInputs fields) inputs) $ \(reference, json) -> Standalone.input reference >>= (@?= Right json)
      outputs <- optionalArray "outputs" bodyJson
      length outputs @?= length (Fields.fieldOutputs fields)
      forM_ (zip (Fields.fieldOutputs fields) outputs) $ \(output, json) -> do
        Standalone.output output >>= (@?= Right json)
        amount <- field "amount" json
        Standalone.value (Output.value output) >>= (@?= Right amount)
        let expectedDatum = case json of
              Object entries -> KeyMap.lookup "datum" entries
              _ -> Nothing
        Standalone.datum (Output.datum output) >>= (@?= Right expectedDatum)
        reference <- Input.input <$> must (TxId.fromBytes (B.replicate 32 0)) <*> pure 0
        let inputJson = object ["transaction_id" .= Text.replicate 64 "0", "index" .= (0 :: Int)]
        Standalone.utxo (Utxo.utxo reference output) >>= (@?= Right (object ["input" .= inputJson, "output" .= json]))
      certs <- optionalArray "certs" bodyJson
      forM_ (zip (maybe [] Certificates.toList (Fields.fieldCertificates fields)) certs) $ \(cert, json) ->
        Standalone.certificate cert >>= (@?= Right json)
      let typed = Witnesses.toWitnesses witnesses
      keyJson <- optionalArray "vkey_witnesses" witnessJson
      bootstrapJson <- optionalArray "bootstraps" witnessJson
      traverse (Standalone.verificationWitness >=> must) (Witnesses.verificationWitnesses typed) >>= (@?= keyJson)
      traverse (Standalone.bootstrapWitness >=> must) (Witnesses.bootstrapWitnesses typed) >>= (@?= bootstrapJson)
      redeemers <- optionalArray "redeemers" witnessJson
      forM_ (zip (Witnesses.redeemers typed) redeemers) $ \(redeemer, json) -> Standalone.redeemer redeemer >>= (@?= Right json)
      datums <- optionalArray "plutus_data" witnessJson
      forM_ (zip (Witnesses.datums typed) datums) $ \(datum, json) -> Standalone.plutusData datum >>= (@?= Right json)
      nativeJson <- optionalArray "native_scripts" witnessJson
      plutusJson <- optionalArray "plutus_scripts" witnessJson
      let scripts = Witnesses.scripts typed
          natives = [native | Script.Native native <- scripts]
          plutuses = [plutus | Script.Plutus plutus <- scripts]
      length natives @?= length nativeJson
      length plutuses @?= length plutusJson
      forM_ (zip natives nativeJson) $ \(native, json) -> do
        Standalone.nativeScript native >>= (@?= Right json)
        Standalone.script (Script.Native native) >>= (@?= Right (object ["tag" .= ("native_script" :: Text.Text), "value" .= json]))
      forM_ (zip plutuses plutusJson) $ \(plutus, json) -> do
        Standalone.plutusScript plutus >>= (@?= Right json)
        Standalone.script (Script.Plutus plutus) >>= (@?= Right (object ["tag" .= ("plutus_script" :: Text.Text), "value" .= json]))

keyFixture :: IO (Credential.KeyHash purpose)
keyFixture = must (Credential.keyHashFromBytes (B.replicate 28 1))

standaloneDomains :: IO ()
standaloneDomains = do
  stakeKey <- keyFixture
  poolKey <- keyFixture
  drepKey <- keyFixture
  coldKey <- keyFixture
  hotKey <- keyFixture
  genesis <- keyFixture
  delegate <- keyFixture
  scriptHash <- must (Credential.scriptHashFromBytes (B.replicate 28 2))
  vrf <- must (Pool.vrfKeyHashFromBytes (B.replicate 32 3))
  margin <- must (Unit.mkUnitInterval 1 5)
  url <- must (Anchor.mkUrl "https://example.com/proposal")
  digest <- must (Anchor.dataHashFromBytes (B.replicate 32 4))
  txid <- must (TxId.fromBytes (B.replicate 32 5))
  let stake = Credential.KeyCredential stakeKey
      drep = Credential.KeyCredential drepKey
      account = Reward.fromCredential Network.testnet stake
      anchor = Anchor.Anchor url digest
      keyJson = object ["tag" .= ("pubkey_hash" :: Text.Text), "value" .= Text.replicate 28 "01"]
      scriptJson = object ["tag" .= ("script_hash" :: Text.Text), "value" .= Text.replicate 28 "02"]
      anchorJson = object ["url" .= ("https://example.com/proposal" :: Text.Text), "data_hash" .= Text.replicate 32 "04"]
      identifier = ActionId.ActionId txid 65535
      identifierJson = object ["transaction_id" .= Text.replicate 32 "05", "gov_action_index" .= ("65535" :: Text.Text)]
      pool = Pool.PoolParameters poolKey vrf Nothing 10000 1000 margin account (Set.singleton stakeKey) [] Nothing
      changes = Update.empty {Update.updateMinFeeA = Just maxBound}
      changeJson = object ["min_fee_a" .= ("18446744073709551615" :: Text.Text)]
  paymentKey <- keyFixture
  let native = Native.allOf [Native.signature paymentKey]
      pubkeyJson = object ["tag" .= ("pubkey" :: Text.Text), "pubkey" .= Text.replicate 28 "01"]
      nativeJson = object ["tag" .= ("all" :: Text.Text), "scripts" .= [pubkeyJson]]
  Standalone.nativeScript native >>= (@?= Right nativeJson)
  guardKey <- keyFixture
  let nativeCases =
        [ (Native.signature paymentKey, pubkeyJson),
          (Native.anyOf [Native.signature paymentKey], object ["tag" .= ("any" :: Text.Text), "scripts" .= [pubkeyJson]]),
          (Native.atLeast 1 [Native.signature paymentKey], object ["tag" .= ("n_of_k" :: Text.Text), "scripts" .= [pubkeyJson], "n" .= (1 :: Int)]),
          (Native.invalidBefore 0, object ["tag" .= ("timelock_start" :: Text.Text), "slot" .= ("0" :: Text.Text)]),
          (Native.invalidAfter maxBound, object ["tag" .= ("timelock_expiry" :: Text.Text), "slot" .= ("18446744073709551615" :: Text.Text)]),
          (Native.requireGuard (Credential.KeyCredential guardKey), object ["tag" .= ("require_guard" :: Text.Text), "credential" .= keyJson]),
          (Native.requireGuard (Credential.ScriptCredential scriptHash), object ["tag" .= ("require_guard" :: Text.Text), "credential" .= scriptJson])
        ]
  forM_ nativeCases $ \(condition, expected) -> do
    Standalone.nativeScript condition >>= (@?= Right expected)
    Standalone.script (Script.Native condition) >>= (@?= Right (object ["tag" .= ("native_script" :: Text.Text), "value" .= expected]))
  forM_ [(Plutus.V1, "plutus_v1"), (Plutus.V2, "plutus_v2"), (Plutus.V3, "plutus_v3"), (Plutus.V4, "plutus_v4")] $ \(version, language) -> do
    plutus <- must (Plutus.fromBytes version (B.pack [1, 2]))
    Standalone.plutusScript plutus >>= (@?= Right (object ["language" .= (language :: Text.Text), "bytes" .= ("0102" :: Text.Text)]))
  Standalone.credential stake >>= (@?= Right keyJson)
  Standalone.credential (Credential.ScriptCredential scriptHash :: Credential.Credential Credential.Stake) >>= (@?= Right scriptJson)
  Standalone.drep (DRep.DRepCredential drep) >>= (@?= Right keyJson)
  Standalone.drep DRep.AlwaysAbstain >>= (@?= Right (object ["tag" .= ("always_abstain" :: Text.Text)]))
  Standalone.drep DRep.AlwaysNoConfidence >>= (@?= Right (object ["tag" .= ("always_no_confidence" :: Text.Text)]))
  Standalone.anchor anchor >>= (@?= Right anchorJson)
  Standalone.actionId identifier >>= (@?= Right identifierJson)
  Standalone.protocolUpdate changes >>= (@?= Right changeJson)
  Standalone.value (Coin.lovelace (-1)) >>= assertBool "negative output coin accepted" . isLeft
  Standalone.value (Coin.lovelace (2 ^ (64 :: Int))) >>= assertBool "overflowing output coin accepted" . isLeft
  policy <- must (PolicyId.fromBytes (B.replicate 28 6))
  name <- must (AssetName.fromBytes (B.pack [0, 255, 128]))
  let signedAssets = Coin.fromList [(Asset.Native policy name, -1)]
      expectedAssets = object ["coin" .= ("0" :: Text.Text), "assets" .= object ["06060606060606060606060606060606060606060606060606060606" .= object ["00ff80" .= ("-1" :: Text.Text)]]]
  Standalone.value signedAssets >>= (@?= Right expectedAssets)
  withdrawals <- must (Action.withdrawalsFromList [(account, maxBound)])
  let actions =
        [ (Action.ParameterChange Nothing changes (Just scriptHash), "parameter_change_action"),
          (Action.HardForkInitiation (Just identifier) (Version.ProtocolVersion 12 0), "hard_fork_initiation_action"),
          (Action.TreasuryWithdrawals withdrawals Nothing, "treasury_withdrawals_action"),
          (Action.NoConfidence Nothing, "no_confidence"),
          (Action.UpdateCommittee Nothing (Action.removalsFromList []) Committee.emptyMembers margin, "update_committee"),
          (Action.NewConstitution Nothing (Constitution.Constitution anchor Nothing), "new_constitution"),
          (Action.InfoAction, "info_action")
        ]
  forM_ actions $ \(action, tag) -> do
    result <- Standalone.governanceAction action >>= must
    field "tag" result >>= (@?= String tag)
    let proposal = Proposal.Proposal maxBound account action anchor
        expected = object ["deposit" .= ("18446744073709551615" :: Text.Text), "reward_account" .= Reward.toText account, "gov_action" .= result, "anchor" .= anchorJson]
    Standalone.proposal proposal >>= (@?= Right expected)
    Internal.runUnchecked 19 (Action.encodeCbor action <> B.singleton 0) >>= assertBool "Trailing action accepted" . isLeft
  let target = DRep.DRepCredential drep
      certificates =
        [ Certificate.StakeRegistration stake,
          Certificate.StakeDeregistration stake,
          Certificate.StakeDelegation stake poolKey,
          Certificate.PoolRegistration pool,
          Certificate.PoolRetirement poolKey maxBound,
          Certificate.GenesisKeyDelegation genesis delegate vrf,
          Certificate.MoveInstantaneousRewards (Certificate.ToOtherPot Certificate.Reserves 1),
          Certificate.MoveInstantaneousRewards (Certificate.ToStakeCredentials Certificate.Treasury (Map.singleton stake 1)),
          Certificate.Registration stake 1,
          Certificate.Unregistration stake 1,
          Certificate.VoteDelegation stake target,
          Certificate.StakeVoteDelegation stake poolKey target,
          Certificate.StakeRegistrationDelegation stake poolKey 1,
          Certificate.VoteRegistrationDelegation stake target 1,
          Certificate.StakeVoteRegistrationDelegation stake poolKey target 1,
          Certificate.AuthorizeCommitteeHot (Credential.KeyCredential coldKey) (Credential.KeyCredential hotKey),
          Certificate.ResignCommitteeCold (Credential.KeyCredential coldKey) (Just anchor),
          Certificate.RegisterDRep drep 1 (Just anchor),
          Certificate.UnregisterDRep drep 1,
          Certificate.UpdateDRep drep (Just anchor)
        ]
  forM_ certificates $ \cert -> do
    standalone <- Standalone.certificate cert >>= must
    encoded <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldCertificates = Just (Certificates.fromList [cert])}}))
    parent <- Inspection.body encoded >>= must
    optionalArray "certs" parent >>= (@?= [standalone])
    Internal.runUnchecked 7 (Certificate.encodeCbor cert <> B.singleton 0) >>= assertBool "Trailing certificate accepted" . isLeft
  poolCert <- Standalone.certificate (Certificate.PoolRegistration pool) >>= must
  poolJson <- field "pool_params" poolCert
  Standalone.poolParameters pool >>= (@?= Right poolJson)
  let voter = Voting.DRepVoter drep
      votes = Voting.singleton voter identifier (Voting.VotingProcedure Voting.Yes (Just anchor))
  votesBody <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldVotingProcedures = Just votes}}))
  votesJson <- Inspection.body votesBody >>= must >>= field "voting_procedures"
  Standalone.votingProcedures votes >>= (@?= Right votesJson)
  retained <- replicateM 20 (Standalone.anchor anchor >>= must)
  performGC
  retained @?= replicate 20 anchorJson

  let address = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential paymentKey))
      datum = Data.fromData (Data.Integer (2 ^ (160 :: Int)))
  output <- must (Output.mkOutput address (Coin.lovelace 2000000) (Datum.InlineDatum datum) (Just (Script.Native native)))
  let reference = Input.input txid 0
      resolved = Utxo.utxo reference output
      proposal = Proposal.Proposal 1 account Action.InfoAction anchor
  amountBytes <- must (Coin.encodeCbor signedAssets)
  bytesMetadata <- must (Metadata.mkBytes (B.pack [0, 255, 128]))
  textMetadata <- must (Metadata.mkText "世界")
  lowMetadata <- must (Metadata.mkInteger (negate (2 ^ (64 :: Int))))
  highMetadata <- must (Metadata.mkInteger (2 ^ (64 :: Int) - 1))
  let tagged tag payload = object ["tag" .= (tag :: Text.Text), "value" .= payload]
      bytesJson = tagged "bytes" ("00ff80" :: Text.Text)
      textJson = tagged "string" ("世界" :: Text.Text)
      lowJson = tagged "int" ("-18446744073709551616" :: Text.Text)
      highJson = tagged "int" ("18446744073709551615" :: Text.Text)
      composite = Metadata.map [(bytesMetadata, Metadata.list [lowMetadata, highMetadata, textMetadata]), (bytesMetadata, textMetadata)]
      listJson = object ["tag" .= ("list" :: Text.Text), "contents" .= [lowJson, highJson, textJson]]
      compositeJson = object ["tag" .= ("map" :: Text.Text), "contents" .= [object ["key" .= bytesJson, "value" .= listJson], object ["key" .= bytesJson, "value" .= textJson]]]
      metadata = Metadata.singleton maxBound composite
      metadataJson = [object ["key" .= ("18446744073709551615" :: Text.Text), "value" .= compositeJson]]
  Standalone.metadatum composite >>= (@?= Right compositeJson)
  Standalone.metadata metadata >>= (@?= Right (toJSON metadataJson))
  encodedMetadata <- must (Metadata.decodeCbor (Metadata.encodeCbor metadata))
  plutus <- must (Plutus.fromBytes Plutus.V4 (B.pack [1, 2]))
  let auxiliary = Auxiliary.fromAuxiliaryData (Auxiliary.auxiliaryData (Just encodedMetadata) (Just [native]) [plutus])
      auxiliaryJson = object ["metadata" .= metadataJson, "native_scripts" .= [nativeJson], "plutus_scripts" .= [object ["language" .= ("plutus_v4" :: Text.Text), "bytes" .= ("0102" :: Text.Text)]]]
  Standalone.auxiliaryData auxiliary >>= (@?= Right auxiliaryJson)
  datumHash <- must (Datum.hashFromBytes (B.replicate 32 7))
  Standalone.datum Datum.NoDatum >>= (@?= Right Nothing)
  Standalone.datum (Datum.DatumHash datumHash) >>= (@?= Right (Just (tagged "datum_hash" (Text.replicate 32 "07"))))
  expectedData <- Standalone.plutusData datum >>= must
  Standalone.datum (Datum.InlineDatum datum) >>= (@?= Right (Just (tagged "datum" expectedData)))
  let redeemer = Redeemer.Redeemer Redeemer.Guarding 0 datum (ExUnits.ExUnits 1 2)
      datumEncoding = Write.toStrictByteString (Encoding.encodeListLen 2 <> Encoding.encodeWord 1 <> Encoding.encodeTag 24 <> Encoding.encodeBytes (Data.toCbor datum))
  let encodings =
        [ (4, amountBytes),
          (5, Script.encodeCbor (Script.Native native)),
          (6, Credential.encodeCbor stake),
          (7, Certificate.encodeCbor (Certificate.Registration stake 1)),
          (8, Proposal.encodeCbor proposal),
          (9, Pool.encodeCbor pool),
          (10, Update.encodeCbor changes),
          (11, Data.toCbor datum),
          (12, Output.encodeCbor output),
          (13, Witnesses.toCbor (Witnesses.fromWitnesses Witnesses.empty)),
          (14, Utxo.encodeCbor resolved),
          (15, DRep.encodeCbor DRep.AlwaysAbstain),
          (16, ActionId.encodeCbor identifier),
          (17, Anchor.encodeCbor anchor),
          (18, Voting.encodeCbor votes),
          (19, Action.encodeCbor Action.InfoAction),
          (20, Metadata.encodeMetadatumCbor composite),
          (21, Metadata.encodeCbor metadata),
          (22, Auxiliary.toCbor auxiliary),
          (23, Input.encodeCbor reference),
          (24, datumEncoding),
          (25, Redeemer.encodeCbor redeemer)
        ]
  snapshots <- forM encodings $ \(kind, bytes) -> do
    let original = B.copy bytes
    result <- Internal.inspect "inspection.lifecycle" kind bytes >>= must
    replicateM_ 10 $ do
      Internal.runUnchecked kind (bytes <> B.singleton 0) >>= assertBool "Trailing standalone CBOR accepted" . isLeft
      Internal.runUnchecked kind (B.take (B.length bytes - 1) bytes) >>= assertBool "Truncated standalone CBOR accepted" . isLeft
    after <- Internal.inspect "inspection.lifecycle" kind bytes >>= must
    after @?= result
    bytes @?= original
    pure result
  rendered <- traverse (evaluate . Lazy.toStrict . encode) snapshots
  performGC
  map (Lazy.toStrict . encode) snapshots @?= rendered

-- Expected objects follow the pinned native writers, not global JSON instances.
standaloneLeaves :: IO ()
standaloneLeaves = do
  stake <- keyFixture
  pool <- keyFixture
  committee <- keyFixture
  scriptHash <- must (Credential.scriptHashFromBytes (B.replicate 28 2))
  location <- must (Anchor.mkUrl "https://example.com/constitution")
  digest <- must (Anchor.dataHashFromBytes (B.replicate 32 3))
  dns <- must (Relay.mkDnsName "relay.example.com")
  ipv4 <- must (Relay.ipv4FromText "192.0.2.1")
  ipv6 <- must (Relay.ipv6FromText "2001:0db8:0000:0000:0000:0000:0000:0001")
  metadataUrl <- must (PoolMetadata.mkUrl "")
  metadataHash <- must (PoolMetadata.metadataHashFromBytes (B.replicate 32 4))
  key <- must (PublicKey.fromBytes (B.replicate 32 5))
  signature <- must (Signature.fromBytes (B.replicate 64 6))
  bootstrap <- must (Witness.mkBootstrapWitness key signature (B.replicate 32 7) (B.pack [0, 255]))
  let anchor = Anchor.Anchor location digest
      anchorJson = object ["url" .= ("https://example.com/constitution" :: Text.Text), "data_hash" .= Text.replicate 32 "03"]
      keyJson = object ["tag" .= ("pubkey_hash" :: Text.Text), "value" .= Text.replicate 28 "01"]
      scriptJson = object ["tag" .= ("script_hash" :: Text.Text), "value" .= Text.replicate 28 "02"]
      witness = Witness.verificationWitness key signature
      witnessJson = object ["vkey" .= Text.replicate 32 "05", "signature" .= Text.replicate 64 "06"]
      bootstrapJson = object ["vkey" .= Text.replicate 32 "05", "signature" .= Text.replicate 64 "06", "chain_code" .= Text.replicate 32 "07", "attributes" .= ("00ff" :: Text.Text)]
      check kind bytes action expected = do
        action >>= (@?= Right expected)
        forM_ [B.empty, B.take (B.length bytes - 1) bytes, bytes <> B.singleton 0] (Internal.runUnchecked kind >=> (assertBool "Invalid leaf CBOR accepted" . isLeft))
        snapshots <- replicateM 5 (action >>= must)
        performGC
        snapshots @?= replicate 5 expected
  check 26 (ExUnits.encodeCbor (ExUnits.ExUnits 0 maxBound)) (Standalone.exUnits (ExUnits.ExUnits 0 maxBound)) (object ["mem" .= ("0" :: Text.Text), "steps" .= ("18446744073709551615" :: Text.Text)])
  forM_ [0, maxBound] $ \minor -> do
    let version = Version.ProtocolVersion maxBound minor
    check 27 (Version.encodeCbor version) (Standalone.protocolVersion version) (object ["major" .= (18446744073709551615 :: Integer), "minor" .= toInteger minor])
  forM_ [(0, 1), (1, 3), (2 ^ (64 :: Int) - 1, 2 ^ (64 :: Int) - 1)] $ \(numerator, denominator) -> do
    interval <- must (Unit.mkUnitInterval numerator denominator)
    check 28 (Unit.encodeCbor interval) (Standalone.unitInterval interval) (object ["numerator" .= Text.pack (show (Unit.numerator interval)), "denominator" .= Text.pack (show (Unit.denominator interval))])
  let relayCases =
        [ (Relay.SingleHostAddress Nothing Nothing Nothing, object ["tag" .= ("single_host_addr" :: Text.Text), "port" .= Null, "ipv4" .= Null, "ipv6" .= Null]),
          (Relay.SingleHostAddress (Just 65535) (Just ipv4) Nothing, object ["tag" .= ("single_host_addr" :: Text.Text), "port" .= (65535 :: Int), "ipv4" .= ("192.0.2.1" :: Text.Text), "ipv6" .= Null]),
          (Relay.SingleHostAddress (Just 0) (Just ipv4) (Just ipv6), object ["tag" .= ("single_host_addr" :: Text.Text), "port" .= (0 :: Int), "ipv4" .= ("192.0.2.1" :: Text.Text), "ipv6" .= ("2001:0db8:0000:0000:0000:0000:0000:0001" :: Text.Text)]),
          (Relay.SingleHostName Nothing dns, object ["tag" .= ("single_host_name" :: Text.Text), "port" .= Null, "dns_name" .= ("relay.example.com" :: Text.Text)]),
          (Relay.MultiHostName dns, object ["tag" .= ("multi_host_name" :: Text.Text), "dns_name" .= ("relay.example.com" :: Text.Text)])
        ]
  forM_ relayCases $ \(relay, json) -> check 29 (Relay.encodeCbor relay) (Standalone.relay relay) json
  let metadata = PoolMetadata.Metadata metadataUrl metadataHash
  check 30 (PoolMetadata.encodeCbor metadata) (Standalone.poolMetadata metadata) (object ["url" .= ("" :: Text.Text), "hash" .= Text.replicate 32 "04"])
  forM_ [Nothing, Just scriptHash] $ \guard -> do
    let constitution = Constitution.Constitution anchor guard
        fields = ["anchor" .= anchorJson] <> maybe [] (const ["script_hash" .= Text.replicate 28 "02"]) guard
    check 31 (Constitution.encodeCbor constitution) (Standalone.constitution constitution) (object fields)
  let voterCases =
        [ (Voting.CommitteeVoter (Credential.KeyCredential committee), object ["tag" .= ("cc_credential" :: Text.Text), "credential" .= keyJson]),
          (Voting.CommitteeVoter (Credential.ScriptCredential scriptHash), object ["tag" .= ("cc_credential" :: Text.Text), "credential" .= scriptJson]),
          (Voting.DRepVoter (Credential.KeyCredential stake), object ["tag" .= ("drep_credential" :: Text.Text), "credential" .= keyJson]),
          (Voting.DRepVoter (Credential.ScriptCredential scriptHash), object ["tag" .= ("drep_credential" :: Text.Text), "credential" .= scriptJson]),
          (Voting.StakePoolVoter pool, object ["tag" .= ("spo_keyhash" :: Text.Text), "pubkey_hash" .= Text.replicate 28 "01"])
        ]
  forM_ voterCases $ \(voter, json) -> check 32 (Voting.encodeVoter voter) (Standalone.voter voter) json
  forM_ [(Voting.No, "no"), (Voting.Yes, "yes"), (Voting.Abstain, "abstain")] $ \(vote, label) ->
    forM_ [Nothing, Just anchor] $ \explanation -> do
      let procedure = Voting.VotingProcedure vote explanation
          fields = ["vote" .= (label :: Text.Text)] <> maybe [] (const ["anchor" .= anchorJson]) explanation
      check 33 (Voting.encodeProcedure procedure) (Standalone.votingProcedure procedure) (object fields)
  check 34 (Witness.encodeCbor witness) (Standalone.verificationWitness witness) witnessJson
  check 35 (Witness.encodeBootstrapCbor bootstrap) (Standalone.bootstrapWitness bootstrap) bootstrapJson

  -- Array inspectors preserve order and duplicate entries, including witnesses.
  supplied <- must (Witnesses.mkWitnesses [witness, witness] [bootstrap, bootstrap] [] [] [])
  parent <- Standalone.witnesses (Witnesses.fromWitnesses supplied) >>= must
  field "vkey_witnesses" parent >>= (@?= toJSON [witnessJson, witnessJson])
  field "bootstraps" parent >>= (@?= toJSON [bootstrapJson, bootstrapJson])
  emptyParent <- Standalone.witnesses (Witnesses.fromWitnesses Witnesses.empty) >>= must
  optionalArray "vkey_witnesses" emptyParent >>= (@?= [])
  optionalArray "bootstraps" emptyParent >>= (@?= [])

-- Complete CBOR values exercise schema checks separately from framing errors.
standaloneLeafFailures :: IO ()
standaloneLeafFailures = do
  let array entries = Encoding.encodeListLen (fromIntegral (length entries)) <> mconcat entries
      bytes size = Encoding.encodeBytes (B.replicate size 0)
      invalidCases =
        [ (26, "negative memory", array [Encoding.encodeInt (-1), Encoding.encodeWord 0]),
          (27, "minor exceeds Word32", array [Encoding.encodeWord 0, Encoding.encodeWord64 4294967296]),
          (28, "wrong rational tag", Encoding.encodeTag 29 <> array [Encoding.encodeWord 0, Encoding.encodeWord 1]),
          (29, "unknown relay kind", array [Encoding.encodeWord 3]),
          (30, "metadata hash has integer type", array [Encoding.encodeString "", Encoding.encodeWord 0]),
          (31, "constitution anchor is null", array [Encoding.encodeNull, Encoding.encodeNull]),
          (32, "unknown voter role", array [Encoding.encodeWord 5, bytes 28]),
          (33, "unknown vote choice", array [Encoding.encodeWord 3, Encoding.encodeNull]),
          (34, "short verification key", array [bytes 31, bytes 64]),
          (34, "short signature", array [bytes 32, bytes 63]),
          (35, "bootstrap attributes have integer type", array [bytes 32, bytes 64, bytes 32, Encoding.encodeWord 0]),
          (35, "short bootstrap verification key", array [bytes 31, bytes 64, bytes 32, bytes 0])
        ]
  forM_ invalidCases $ \(kind, label, encoded) -> do
    result <- Internal.runUnchecked kind (Write.toStrictByteString encoded)
    assertBool ("Schema-invalid leaf accepted: " <> label) (isLeft result)

-- Protocol and Dijkstra collection schemas differ from ordinary JSON arrays:
-- language-keyed objects, genesis-keyed objects and ordered key/value entries.
standaloneCollections :: IO ()
standaloneCollections = do
  model <- must (Models.mkCostModel 0 [negate (2 ^ (63 :: Int)), 0, 2 ^ (63 :: Int) - 1])
  future <- must (Models.mkCostModel 255 [7])
  laterModels <- traverse (\language -> must (Models.mkCostModel language [fromIntegral language])) [1, 2, 3]
  let models = Models.fromList (future : model : laterModels)
      modelJson = toJSON (["-9223372036854775808", "0", "9223372036854775807"] :: [Text.Text])
      modelsJson = object ["plutus_v1" .= modelJson, "plutus_v2" .= (["1"] :: [Text.Text]), "plutus_v3" .= (["2"] :: [Text.Text]), "plutus_v4" .= (["3"] :: [Text.Text])]
      modelBytes supplied = Write.toStrictByteString (Encoding.encodeListLen 2 <> Encoding.encodeWord8 (Models.languageId supplied)) <> Models.encodeCostModelCbor supplied
      check kind bytes action expected = do
        let original = B.copy bytes
        action >>= (@?= Right expected)
        forM_ [B.empty, B.take (B.length bytes - 1) bytes, bytes <> B.singleton 0] (Internal.runUnchecked kind >=> (assertBool "Invalid collection CBOR accepted" . isLeft))
        snapshots <- replicateM 5 (action >>= must)
        performGC
        snapshots @?= replicate 5 expected
        bytes @?= original
      fraction numerator denominator = object ["numerator" .= (numerator :: Text.Text), "denominator" .= (denominator :: Text.Text)]
  check 36 (modelBytes model) (Standalone.costModel model) modelJson
  check 36 (modelBytes future) (Standalone.costModel future) (toJSON (["7"] :: [Text.Text]))
  check 37 (Models.encodeCbor models) (Standalone.costModels models) modelsJson
  Standalone.costModels Models.empty >>= (@?= Right (object []))
  map Models.languageId (Models.toList models) @?= [0, 1, 2, 3, 255]
  let originalModelBytes = Models.encodeCbor models
  Standalone.costModels (Models.fromList [future]) >>= (@?= Right (object []))
  Models.encodeCbor models @?= originalModelBytes
  -- Prices may exceed one and fractions remain unreduced in native JSON.
  memoryPrice <- must (Rational.mkNonNegativeRational 6 4)
  stepPrice <- must (Rational.mkNonNegativeRational 2 6)
  let prices = Prices.ExUnitPrices memoryPrice stepPrice
      pricesJson = object ["mem_price" .= fraction "6" "4", "step_price" .= fraction "2" "6"]
  check 38 (Prices.encodeCbor prices) (Standalone.exUnitPrices prices) pricesJson
  thresholds <- traverse (\numerator -> must (Unit.mkUnitInterval numerator 10)) [0 .. 9]
  case thresholds of
    [a, b, c, d, e, f, g, h, i, j] -> do
      let pool = PoolThresholds.PoolVotingThresholds a b c d e
          drep = DRepThresholds.DRepVotingThresholds a b c d e f g h i j
          poolNames = ["motion_no_confidence", "committee_normal", "committee_no_confidence", "hard_fork_initiation", "security_relevant_param"]
          drepNames = ["motion_no_confidence", "committee_normal", "committee_no_confidence", "update_constitution", "hard_fork_initiation", "pp_network_group", "pp_economic_group", "pp_technical_group", "pp_gov_group", "treasury_withdrawal"]
          thresholdJson names = object [name .= fraction (Text.pack (show numerator)) "10" | (name, numerator) <- zip names ([0 ..] :: [Int])]
          poolJson = thresholdJson poolNames
          drepJson = thresholdJson drepNames
          update = Update.empty {Update.updateCostModels = Just models, Update.updateExecutionCosts = Just prices, Update.updatePoolVotingThresholds = Just pool, Update.updateDrepVotingThresholds = Just drep}
          updateJson = object ["cost_models" .= modelsJson, "execution_costs" .= pricesJson, "pool_voting_thresholds" .= poolJson, "drep_voting_thresholds" .= drepJson]
      check 39 (PoolThresholds.encodeCbor pool) (Standalone.poolVotingThresholds pool) poolJson
      check 40 (DRepThresholds.encodeCbor drep) (Standalone.drepVotingThresholds drep) drepJson
      Standalone.protocolUpdate update >>= (@?= Right updateJson)
      genesis <- keyFixture
      proposed <- must (Proposed.fromList [(genesis, update)])
      let proposedJson = object ["01010101010101010101010101010101010101010101010101010101" .= updateJson]
          proposal = Proposed.UpdateProposal maxBound proposed
          proposalJson = object ["epoch" .= (18446744073709551615 :: Integer), "proposed_protocol_parameter_updates" .= proposedJson]
      check 41 (Proposed.encodeCbor proposed) (Standalone.proposedUpdates proposed) proposedJson
      check 42 (Proposed.encodeProposal proposal) (Standalone.updateProposal proposal) proposalJson
      Standalone.proposedUpdates Proposed.empty >>= (@?= Right (object []))
    _ -> assertFailure "Threshold fixture arity"
  stake <- keyFixture
  guard <- keyFixture
  scriptHash <- must (Credential.scriptHashFromBytes (B.replicate 28 2))
  let account = Reward.fromCredential Network.testnet (Credential.KeyCredential stake)
      keyGuard = Credential.KeyCredential guard
      scriptGuard = Credential.ScriptCredential scriptHash
      datum = Data.fromData (Data.Map [(Data.Integer 1, Data.Integer 2), (Data.Integer 1, Data.Integer 3)])
      keyJson = object ["tag" .= ("pubkey_hash" :: Text.Text), "value" .= Text.replicate 28 "01"]
      scriptJson = object ["tag" .= ("script_hash" :: Text.Text), "value" .= Text.replicate 28 "02"]
      exactJson = object ["tag" .= ("exact" :: Text.Text), "value" .= ("18446744073709551615" :: Text.Text)]
      encodeInterval interval = Write.toStrictByteString $ case interval of
        Fields.ExactBalance amount -> Encoding.encodeWord64 amount
        Fields.BalanceRange lower upper -> Encoding.encodeListLen 2 <> maybe Encoding.encodeNull Encoding.encodeWord64 lower <> maybe Encoding.encodeNull Encoding.encodeWord64 upper
      rangeJson lower upper = object ["tag" .= ("range" :: Text.Text), "inclusive_lower_bound" .= lower, "exclusive_upper_bound" .= upper]
      intervalCases =
        [ (Fields.ExactBalance maxBound, exactJson),
          (Fields.BalanceRange Nothing (Just 0), rangeJson Null (String "0")),
          (Fields.BalanceRange (Just maxBound) Nothing, rangeJson (String "18446744073709551615") Null),
          (Fields.BalanceRange (Just 10) (Just 1), rangeJson (String "10") (String "1"))
        ]
  forM_ intervalCases $ \(interval, json) -> check 43 (encodeInterval interval) (Standalone.balanceInterval interval) json
  Standalone.balanceInterval (Fields.BalanceRange Nothing Nothing) >>= assertBool "Unbounded native interval accepted" . isLeft
  intervals <- must (Fields.mkEntries [(account, Fields.ExactBalance maxBound)])
  deposits <- must (Fields.mkEntries [(account, 0)])
  guards <- must (Fields.mkEntries [(scriptGuard, Just datum), (keyGuard, Nothing)])
  datumJson <- Standalone.plutusData datum >>= must
  let entry key payload = object ["key" .= key, "value" .= payload]
      intervalsJson = toJSON [entry (String (Reward.toText account)) exactJson]
      depositsJson = toJSON [entry (String (Reward.toText account)) (String "0")]
      guardsJson = toJSON [entry keyJson Null, entry scriptJson datumJson]
      fields = (Fields.fields [] []) {Fields.fieldAccountBalanceIntervals = Just intervals, Fields.fieldDirectDeposits = Just deposits, Fields.fieldRequiredTopLevelGuards = Just guards}
      association pairs = Write.toStrictByteString (Encoding.encodeMapLen (fromIntegral (length pairs))) <> foldMap (uncurry (<>)) pairs
      intervalBytes = association [(Write.toStrictByteString (Encoding.encodeBytes (Reward.toBytes account)), encodeInterval (Fields.ExactBalance maxBound))]
      depositsBytes = association [(Write.toStrictByteString (Encoding.encodeBytes (Reward.toBytes account)), Write.toStrictByteString (Encoding.encodeWord64 0))]
      guardsBytes = association [(Credential.encodeCbor keyGuard, Write.toStrictByteString Encoding.encodeNull), (Credential.encodeCbor scriptGuard, Data.toCbor datum)]
  check 44 intervalBytes (Standalone.balanceIntervals intervals) intervalsJson
  check 45 depositsBytes (Standalone.directDeposits deposits) depositsJson
  check 46 guardsBytes (Standalone.requiredGuards guards) guardsJson
  body <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = fields}))
  bodyJson <- Inspection.body body >>= must
  field "account_balance_intervals" bodyJson >>= (@?= intervalsJson)
  field "direct_deposits" bodyJson >>= (@?= depositsJson)
  field "required_top_level_guards" bodyJson >>= (@?= guardsJson)
  subBody <- must (SubBody.fromBody (SubBody.fromFields fields))
  subJson <- Inspection.subBody subBody >>= must
  field "account_balance_intervals" subJson >>= (@?= intervalsJson)
  field "direct_deposits" subJson >>= (@?= depositsJson)
  field "required_top_level_guards" subJson >>= (@?= guardsJson)
  -- Well-framed invalid schemas exercise native validation independently of framing.
  let array entries = Encoding.encodeListLen (fromIntegral (length entries)) <> mconcat entries
      invalid =
        [ (36, array [Encoding.encodeWord 256, array []]),
          (37, Encoding.encodeMapLen 1 <> Encoding.encodeWord 0 <> Encoding.encodeString "costs"),
          (38, array [Encoding.encodeNull, Encoding.encodeNull]),
          (39, array []),
          (40, array []),
          (41, Encoding.encodeMapLen 1 <> Encoding.encodeWord 0 <> Encoding.encodeMapLen 0),
          (42, array [Encoding.encodeMapLen 0, Encoding.encodeString "epoch"]),
          (43, array [Encoding.encodeNull, Encoding.encodeNull]),
          (44, Encoding.encodeMapLen 1 <> Encoding.encodeWord 0 <> Encoding.encodeWord 0),
          (45, Encoding.encodeMapLen 1 <> Encoding.encodeWord 0 <> Encoding.encodeWord 0),
          (46, Encoding.encodeMapLen 1 <> array [Encoding.encodeWord 0, Encoding.encodeBytes B.empty] <> Encoding.encodeNull)
        ]
  forM_ invalid $ \(kind, bytes) -> Internal.runUnchecked kind (Write.toStrictByteString bytes) >>= assertBool "Invalid standalone collection schema accepted" . isLeft
