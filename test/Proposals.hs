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

-- | Pure proposal workflows and pinned native fresh-construction differential tests.
-- Imported CBOR constants: cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/proposal_procedures/{hard_fork_initiation_action,treasury_withdrawals_action,
-- no_confidence_action,update_committee_action,new_constitution_action,info_action}.cpp.
-- Copyright Biglup Labs, Apache-2.0. Properties and generators are original Cometa tests.
module Proposals (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Committee as Committee
import qualified Cometa.Governance.Constitution as Constitution
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters.Update as Update
import qualified Cometa.Protocol.ProposedUpdates as Legacy
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.TransactionId as TxId
import qualified Cometa.UnitInterval as Interval
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Either (isLeft)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Governance proposals"
    [ testCase "all seven actions reconstruct freshly with optional fields" checkActions,
      testCase "proposals preserve order, duplicates, and unsigned amount bounds" checkProposals,
      testCase "committee and constitution reconstruct fields" checkCommittee,
      testCase "legacy maps and envelopes reconstruct sorted updates" checkLegacy,
      testCase "invalid schemas and duplicate map keys are rejected" checkInvalid,
      testCase "exact wrappers preserve nonminimal and indefinite encodings" checkExact,
      testCase "pinned native corpus decodes through public semantic values" checkPinned,
      testCase "repeated retained-getter reconstruction releases all local owners" checkRepeated,
      testProperty "amount and policy boundaries round trip and agree with native" propRoundTrip,
      testProperty "ordered proposal append is associative with empty identity" propAppend
    ]

sampleAnchor :: Either Error Anchor.Anchor
sampleAnchor = Anchor.Anchor <$> Anchor.mkUrl "https://www.someurl.io" <*> Anchor.dataHashFromBytes (BS.replicate 32 0)

sampleAccount :: Word8 -> Either Error Reward.RewardAddress
sampleAccount prefix =
  Reward.fromCredential Network.testnet . Credential.KeyCredential
    <$> Credential.keyHashFromBytes (BS.replicate 28 prefix)

sampleActions :: Word64 -> Either Error [Action.Action]
sampleActions amount = do
  anchor <- sampleAnchor
  account <- sampleAccount 2
  secondAccount <- sampleAccount 1
  cold <- Credential.KeyCredential <$> Credential.keyHashFromBytes (BS.replicate 28 1)
  script <- Credential.ScriptCredential <$> Credential.scriptHashFromBytes (BS.replicate 28 2)
  policy <- Credential.scriptHashFromBytes (BS.replicate 28 3)
  tx <- TxId.fromBytes (BS.replicate 32 0)
  let previous = ActionId.ActionId tx maxBound
  members <- Committee.membersFromList [(script, amount), (cold, 0)]
  withdrawals <- Action.withdrawalsFromList [(account, amount), (secondAccount, 0)]
  quorum <- Interval.mkUnitInterval 2 3
  let changes = Update.empty {Update.updateMinFeeA = Just amount}
  pure
    [ Action.ParameterChange Nothing changes Nothing,
      Action.ParameterChange (Just previous) changes (Just policy),
      Action.HardForkInitiation Nothing (Version.ProtocolVersion maxBound maxBound),
      Action.HardForkInitiation (Just previous) (Version.ProtocolVersion 9 0),
      Action.TreasuryWithdrawals withdrawals Nothing,
      Action.TreasuryWithdrawals withdrawals (Just policy),
      Action.NoConfidence Nothing,
      Action.NoConfidence (Just previous),
      Action.UpdateCommittee Nothing (Action.removalsFromList []) Committee.emptyMembers quorum,
      Action.UpdateCommittee (Just previous) (Action.removalsFromList [script, cold, cold]) members quorum,
      Action.NewConstitution Nothing (Constitution.Constitution anchor Nothing),
      Action.NewConstitution (Just previous) (Constitution.Constitution anchor (Just policy)),
      Action.InfoAction
    ]

modeOf :: Action.Action -> CUInt
modeOf action = case action of
  Action.ParameterChange {} -> 0
  Action.HardForkInitiation {} -> 1
  Action.TreasuryWithdrawals {} -> 2
  Action.NoConfidence {} -> 3
  Action.UpdateCommittee {} -> 4
  Action.NewConstitution {} -> 5
  Action.InfoAction -> 6

checkActions :: IO ()
checkActions = forM_ [0, 1, maxBound] $ \amount -> do
  actions <- expectRight (sampleActions amount)
  forM_ actions $ \action -> do
    let encoded = Action.encodeCbor action
    fmap Action.toAction (Action.decodeCbor encoded) @?= Right action
    nativeAgreement (modeOf action) encoded

sampleProposal :: Word64 -> Action.Action -> Either Error Proposal.Proposal
sampleProposal amount action = Proposal.Proposal amount <$> sampleAccount 1 <*> pure action <*> sampleAnchor

checkProposals :: IO ()
checkProposals = do
  actions <- expectRight (sampleActions maxBound)
  proposals <- traverse (expectRight . sampleProposal maxBound) actions
  forM_ proposals $ \proposal -> do
    fmap Proposal.toProposal (Proposal.decodeCbor (Proposal.encodeCbor proposal)) @?= Right proposal
    nativeAgreement 10 (Proposal.encodeCbor proposal)
  let collection = Proposal.fromList (proposals <> proposals)
  Proposal.toList collection @?= proposals <> proposals
  fmap Proposal.toProposals (Proposal.decodeProposals (Proposal.encodeProposals collection)) @?= Right collection
  nativeAgreement 11 (Proposal.encodeProposals collection)
  nativeAgreement 11 (Proposal.encodeProposals Proposal.empty)

checkCommittee :: IO ()
checkCommittee = do
  anchor <- expectRight sampleAnchor
  policy <- expectRight (Credential.scriptHashFromBytes (BS.replicate 28 5))
  forM_ [Nothing, Just policy] $ \script -> do
    let constitution = Constitution.Constitution anchor script
    Constitution.decodeCbor (Constitution.encodeCbor constitution) @?= Right constitution
    nativeAgreement 7 (Constitution.encodeCbor constitution)
  cold <- Credential.KeyCredential <$> expectRight (Credential.keyHashFromBytes (BS.replicate 28 0))
  script <- Credential.ScriptCredential <$> expectRight (Credential.scriptHashFromBytes (BS.replicate 28 1))
  members <- expectRight (Committee.membersFromList [(script, maxBound), (cold, 0)])
  quorum <- expectRight (Interval.mkUnitInterval 1 1)
  let committee = Committee.Committee members quorum
  Committee.decodeCbor (Committee.encodeCbor committee) @?= Right committee
  nativeAgreement 8 (Committee.encodeCbor committee)
  nativeAgreement 9 (Committee.encodeMembers members)
  Committee.membersFromList [(cold, 0), (cold, 1)] @?= Left DuplicateCommitteeMember

checkLegacy :: IO ()
checkLegacy = do
  high <- expectRight (Credential.keyHashFromBytes (BS.replicate 28 255))
  low <- expectRight (Credential.keyHashFromBytes (BS.replicate 28 0))
  let changes = Update.empty {Update.updateMinFeeB = Just maxBound}
  entries <- expectRight (Legacy.fromList [(high, changes), (low, Update.empty)])
  fmap fst (Legacy.toList entries) @?= [low, high]
  fmap Legacy.toUpdates (Legacy.decodeCbor (Legacy.encodeCbor entries)) @?= Right entries
  nativeAgreement 12 (Legacy.encodeCbor entries)
  forM_ [0, maxBound] $ \epoch -> do
    let proposal = Legacy.UpdateProposal epoch entries
    fmap Legacy.toProposal (Legacy.decodeProposal (Legacy.encodeProposal proposal)) @?= Right proposal
    nativeAgreement 13 (Legacy.encodeProposal proposal)
  Legacy.fromList [(low, changes), (low, Update.empty)] @?= Left DuplicateProtocolUpdate

checkInvalid :: IO ()
checkInvalid = do
  forM_ ["", "00", "8107", "8206f6", "810600", "9f06f6ff", "820321", "8203f5"] $ \hex -> do
    bytes <- hexBytes hex
    assertBool "invalid action rejected" (isLeft (Action.decodeCbor bytes))
  account <- expectRight (sampleAccount 1)
  Action.withdrawalsFromList [(account, 0), (account, 1)] @?= Left DuplicateTreasuryWithdrawal
  let invalidProposal = BS.pack [0x84, 0, 0x40, 0x81, 6, 0x80]
  assertBool "reward account schema enforced" (isLeft (Proposal.decodeCbor invalidProposal))
  let key = "581c" <> replicate 56 '0'
  duplicate <- hexBytes ("a2" <> key <> "a0" <> key <> "a0")
  assertBool "legacy duplicate map rejected" (isLeft (Legacy.decodeCbor duplicate))
  badEpoch <- hexBytes "82a020"
  assertBool "negative epoch rejected" (isLeft (Legacy.decodeProposal badEpoch))

checkExact :: IO ()
checkExact = do
  bytes <- hexBytes "9f1806ff"
  action <- expectRight (Action.decodeCbor bytes)
  Action.toAction action @?= Action.InfoAction
  Action.toCbor action @?= bytes
  Action.encodeCbor (Action.toAction action) @?= BS.pack [0x81, 6]
  proposal <- expectRight (sampleProposal 0 Action.InfoAction)
  let freshProposal = Proposal.encodeCbor proposal
      nonminimalProposal = BS.take 1 freshProposal <> BS.pack [0x18, 0] <> BS.drop 2 freshProposal
  importedProposal <- expectRight (Proposal.decodeCbor nonminimalProposal)
  Proposal.toCbor importedProposal @?= nonminimalProposal
  Proposal.toProposal importedProposal @?= proposal
  listBytes <- hexBytes "9fff"
  collection <- expectRight (Proposal.decodeProposals listBytes)
  Proposal.proposalsCbor collection @?= listBytes
  Proposal.toProposals collection @?= Proposal.empty
  legacyBytes <- hexBytes "9fbfff1800ff"
  legacy <- expectRight (Legacy.decodeProposal legacyBytes)
  Legacy.proposalCbor legacy @?= legacyBytes
  Legacy.toProposal legacy @?= Legacy.UpdateProposal 0 Legacy.empty

checkPinned :: IO ()
checkPinned = forM_ pinnedVectors $ \(mode, hex) -> do
  bytes <- hexBytes hex
  encoded <- expectRight (Action.decodeCbor bytes)
  -- Inspection and fresh reassembly exercise public semantic payloads.
  let semantic = Action.toAction encoded
  Action.toCbor encoded @?= bytes
  nativeAgreement mode (Action.encodeCbor semantic)

checkRepeated :: IO ()
checkRepeated = replicateM_ 30 (checkProposals >> checkLegacy >> checkCommittee)

propRoundTrip :: Property
propRoundTrip = property $ do
  amount <- forAll (Gen.word64 Range.constantBounded)
  actions <- evalEither (sampleActions amount)
  forM_ actions $ \action -> do
    let encoded = Action.encodeCbor action
    fmap Action.toAction (Action.decodeCbor encoded) === Right action
    result <- evalIO (nativeResult (modeOf action) encoded)
    result === 1

propAppend :: Property
propAppend = property $ do
  amounts <- forAll (Gen.list (Range.linear 0 8) (Gen.word64 Range.constantBounded))
  proposals <- evalEither (traverse (`sampleProposal` Action.InfoAction) amounts)
  let a = Proposal.fromList proposals
      b = Proposal.fromList (reverse proposals)
      c = Proposal.fromList (take 1 proposals)
  Proposal.append a Proposal.empty === a
  Proposal.append Proposal.empty a === a
  Proposal.append (Proposal.append a b) c === Proposal.append a (Proposal.append b c)

expectRight :: (Show error) => Either error value -> IO value
expectRight value = case value of
  Left failure -> assertFailure (show failure)
  Right result -> pure result

hexBytes :: String -> IO ByteString
hexBytes value = case Hex.decodeHex (Text.pack value) of
  Nothing -> assertFailure "Invalid test hexadecimal"
  Just result -> pure result

nativeAgreement :: CUInt -> ByteString -> IO ()
nativeAgreement mode bytes = do
  result <- nativeResult mode bytes
  assertBool ("native fresh reconstruction failed, mode " <> show mode) (result == 1)

nativeResult :: CUInt -> ByteString -> IO CInt
nativeResult mode bytes = BS.useAsCStringLen bytes $ \(ptr, size) -> c_agreement mode (castPtr ptr) (fromIntegral size)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_proposals_agreement"
  c_agreement :: CUInt -> Ptr Word8 -> CSize -> IO CInt

-- DEFINITIONS ----------------------------------------------------------------

pinnedVectors :: [(CUInt, String)]
pinnedVectors =
  [ (1, "8301825820000000000000000000000000000000000000000000000000000000000000000003820103"),
    (2, "8302a1581de1cb0ec2692497b458e46812c8a5bfa2931d1a2d965a99893828ec810f01581c8293d319ef5b3ac72366dd28006bd315b715f7e7cfcbd3004129b80d"),
    (3, "8203825820000000000000000000000000000000000000000000000000000000000000000003"),
    (4, "8504825820000000000000000000000000000000000000000000000000000000000000000003d90102828200581c000000000000000000000000000000000000000000000000000000008200581c20000000000000000000000000000000000000000000000000000000a28200581c30000000000000000000000000000000000000000000000000000000018200581c4000000000000000000000000000000000000000000000000000000002d81e820105"),
    (5, "830582582000000000000000000000000000000000000000000000000000000000000000000382827668747470733a2f2f7777772e736f6d6575726c2e696f58200000000000000000000000000000000000000000000000000000000000000000f6"),
    (6, "8106")
  ]
