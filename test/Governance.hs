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

-- | Governance bounds, collection laws, pinned vectors and native reconstruction.
module Governance (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.Binary.Bech32 as Bech32
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.TransactionId as TransactionId
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64, Word8)
import qualified Fixtures.Governance as Fixtures
import Foreign.C.Types (CChar, CInt (..), CSize (..), CUInt (..))
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
    "Governance"
    [ testCase "DRep text imports CIP-105 and exports checked CIP-129 credentials" checkDRepText,
      testCase "CIP-129 action text checks one-byte indices and native correspondence" checkActionText,
      testCase "public values reconstruct pinned anchors, actions, DReps and choices" checkPinnedScalars,
      testCase "all voter authorities and native ordering agree" checkVoters,
      testCase "public nested collection reconstructs pinned native voting corpus" checkPinnedVoting,
      testCase "URL and identity validation enforce byte bounds" checkValidation,
      testCase "schema decoders reject malformed and trailing input" checkInvalid,
      testCase "external map order and nonminimal encoding remain exact" checkExact,
      testCase "duplicates and empty voter maps never silently normalize" checkCollections,
      testCase "native repeated reconstruction releases retained getter outputs" checkRepeated,
      testProperty "typed values round trip and agree with native reconstruction" propRoundTrip,
      testProperty "disjoint vote merge is associative, commutative and has empty identity" propMerge
    ]

sampleAnchor :: IO Anchor.Anchor
sampleAnchor = do
  location <- expectRight (Anchor.mkUrl "https://www.someurl.io")
  digest <- expectRight (Anchor.dataHashFromBytes (ByteString.replicate 32 0))
  pure (Anchor.Anchor location digest)

actionWith :: Word8 -> Word64 -> IO ActionId.ActionId
actionWith prefix actionIndex = do
  transaction <- expectRight (TransactionId.fromBytes (ByteString.cons prefix (ByteString.replicate 31 0)))
  pure (ActionId.ActionId transaction actionIndex)

votersWith :: Word8 -> IO [Voting.Voter]
votersWith prefix = do
  let hashBytes = ByteString.cons prefix (ByteString.replicate 27 0)
  hotKey <- expectRight (Credential.keyHashFromBytes hashBytes)
  drepKey <- expectRight (Credential.keyHashFromBytes hashBytes)
  poolKey <- expectRight (Credential.keyHashFromBytes hashBytes)
  script <- expectRight (Credential.scriptHashFromBytes hashBytes)
  pure
    [ Voting.CommitteeVoter (Credential.KeyCredential hotKey),
      Voting.CommitteeVoter (Credential.ScriptCredential script),
      Voting.DRepVoter (Credential.KeyCredential drepKey),
      Voting.DRepVoter (Credential.ScriptCredential script),
      Voting.StakePoolVoter poolKey
    ]

checkPinnedScalars :: IO ()
checkPinnedScalars = do
  explanation <- sampleAnchor
  anchorBytes <- bytes Fixtures.anchorVector
  Anchor.encodeCbor explanation @?= anchorBytes
  Anchor.decodeCbor anchorBytes @?= Right explanation
  nativeAgreement 0 anchorBytes
  action <- actionWith 0 3
  actionBytes <- bytes Fixtures.actionVector
  ActionId.encodeCbor action @?= actionBytes
  ActionId.decodeCbor actionBytes @?= Right action
  nativeAgreement 1 actionBytes
  key <- expectRight (Credential.keyHashFromBytes (ByteString.replicate 28 0))
  script <- expectRight (Credential.scriptHashFromBytes (ByteString.replicate 28 0))
  let targets = [DRep.DRepCredential (Credential.KeyCredential key), DRep.DRepCredential (Credential.ScriptCredential script), DRep.AlwaysAbstain, DRep.AlwaysNoConfidence]
  forM_ (zip targets Fixtures.drepVectors) $ \(target, golden) -> do
    expected <- bytes golden
    DRep.encodeCbor target @?= expected
    DRep.decodeCbor expected @?= Right target
    nativeAgreement 2 expected
  let procedures = [Voting.VotingProcedure choice maybeAnchor | maybeAnchor <- [Nothing, Just explanation], choice <- [Voting.No, Voting.Yes, Voting.Abstain]]
  forM_ (zip procedures Fixtures.procedureVectors) $ \(procedure, golden) -> do
    expected <- bytes golden
    Voting.encodeProcedure procedure @?= expected
    Voting.decodeProcedure expected @?= Right procedure
    nativeAgreement 4 expected

checkVoters :: IO ()
checkVoters = do
  voters <- votersWith 0
  forM_ (zip [0 ..] voters) $ \(code, voter) -> do
    let expected = ByteString.pack [0x82, code, 0x58, 0x1c] <> ByteString.replicate 28 0
    Voting.encodeVoter voter @?= expected
    Voting.decodeVoter expected @?= Right voter
    nativeAgreement 3 expected
  action <- actionWith 255 maxBound
  votes <- expectRight (Voting.fromList [(voter, action, Voting.VotingProcedure Voting.Abstain Nothing) | voter <- reverse voters])
  map (\(voter, _, _) -> voter) (Voting.toList votes) @?= voters
  nativeAgreement 5 (Voting.encodeCbor votes)

pinnedVoting :: IO Voting.VotingProcedures
pinnedVoting = do
  key <- expectRight (Credential.keyHashFromBytes (ByteString.cons 0x10 (ByteString.replicate 27 0)))
  script <- expectRight (Credential.scriptHashFromBytes (ByteString.cons 0x20 (ByteString.replicate 27 0)))
  actions <- mapM (`actionWith` 3) [0x10, 0x20, 0x30]
  explanation <- sampleAnchor
  let procedure = Voting.VotingProcedure Voting.No (Just explanation)
      keyed = [(Voting.DRepVoter (Credential.KeyCredential key), action, procedure) | action <- actions]
      scripted = [(Voting.DRepVoter (Credential.ScriptCredential script), action, procedure) | (position, action) <- zip [0 :: Int ..] actions, position /= 1]
  expectRight (Voting.fromList (reverse (keyed <> scripted)))

checkPinnedVoting :: IO ()
checkPinnedVoting = do
  value <- pinnedVoting
  expected <- bytes Fixtures.votingVector
  Voting.encodeCbor value @?= expected
  encoded <- expectRight (Voting.decodeCbor expected)
  Voting.toVotingProcedures encoded @?= value
  Voting.toCbor encoded @?= expected
  nativeAgreement 5 expected

checkValidation :: IO ()
checkValidation = do
  Anchor.mkUrl "" @?= Left (InvalidAnchorUrlLength 0)
  Anchor.mkUrl (Text.replicate 129 "a") @?= Left (InvalidAnchorUrlLength 129)
  Anchor.mkUrl "a\0b" @?= Left InvalidAnchorUrl
  valid <- expectRight (Anchor.mkUrl (Text.replicate 64 "é"))
  ByteString.length (Text.encodeUtf8 (Anchor.urlText valid)) @?= 128
  assertBool "UTF8 byte bound" (isLeft (Anchor.mkUrl (Text.replicate 65 "é")))
  forM_ [0, 31, 33] $ \size -> do
    Anchor.dataHashFromBytes (ByteString.replicate size 0) @?= Left (InvalidAnchorDataHashLength size)
    TransactionId.fromBytes (ByteString.replicate size 0) @?= Left (InvalidTransactionIdLength size)
  transaction <- expectRight (TransactionId.fromHex (Text.replicate 64 "A"))
  TransactionId.toHex transaction @?= Text.replicate 64 "a"
  TransactionId.fromHex "zz" @?= Left InvalidHex
  emptyHash <- Anchor.hashData ByteString.empty
  assertBool "empty payload retains native hash failure" (case emptyHash of Left NativeError {} -> True; _ -> False)
  digest <- Anchor.hashData "Hello, World!" >>= expectRight
  expectedDigest <- bytes "511bc81dde11180838c562c82bb35f3223f46061ebde4a955c27b3f489cf1e03"
  Anchor.dataHashBytes digest @?= expectedDigest
  forM_ [0, 255, 256, 65535, 65536, maxBound] $ \actionIndex -> do
    action <- actionWith 7 actionIndex
    ActionId.decodeCbor (ActionId.encodeCbor action) @?= Right action
    nativeAgreement 1 (ActionId.encodeCbor action)

checkInvalid :: IO ()
checkInvalid = do
  forM_ ["", "80", "8100", "820440", "820140", "83004000", "810200", "9f0200ff", "8200581b" <> replicate 54 '0'] $ \hex -> do
    input <- bytes hex
    assertBool "invalid DRep rejected" (isLeft (DRep.decodeCbor input))
  forM_ ["820540", "820440", "8100", "83004000", "8200581d" <> replicate 58 '0'] $ \hex -> do
    input <- bytes hex
    assertBool "invalid voter rejected" (isLeft (Voting.decodeVoter input))
  forM_ ["8203f6", "8100", "8300f600", "8200f4", "8200f600"] $ \hex -> do
    input <- bytes hex
    assertBool "invalid choice/anchor rejected" (isLeft (Voting.decodeProcedure input))
  forM_ ["a0f6", "80", "a100a0", "bf00a0ff"] $ \hex -> do
    input <- bytes hex
    assertBool "invalid collection rejected" (isLeft (Voting.decodeCbor input))
  action <- actionWith 0 0
  let actionBytes = ActionId.encodeCbor action
  assertBool "negative index" (isLeft (ActionId.decodeCbor (ByteString.init actionBytes <> ByteString.singleton 0x20)))
  assertBool "trailing action bytes" (isLeft (ActionId.decodeCbor (actionBytes <> ByteString.singleton 0)))
  forM_ ["82605820" <> replicate 64 '0', "82636100625820" <> replicate 64 '0', "8261ff5820" <> replicate 64 '0'] $ \hex -> do
    input <- bytes hex
    assertBool "invalid URL anchor rejected" (isLeft (Anchor.decodeCbor input))

checkExact :: IO ()
checkExact = do
  voters <- votersWith 0
  action <- actionWith 0 0
  let procedure = Voting.VotingProcedure Voting.Yes Nothing
      entries = [(voter, action, procedure) | voter <- reverse voters]
      pair (voter, proposal, _) = Voting.encodeVoter voter <> ByteString.singleton 0xbf <> ActionId.encodeCbor proposal <> ByteString.pack [0x9f, 0x18, 1, 0xf6, 0xff, 0xff]
      original = ByteString.pack [0xb8, 5] <> foldMap pair entries
  decoded <- expectRight (Voting.decodeCbor original)
  semantic <- expectRight (Voting.fromList entries)
  Voting.toVotingProcedures decoded @?= semantic
  Voting.toCbor decoded @?= original
  assertBool "fresh serialization is different" (Voting.encodeCbor semantic /= original)
  assertBool "encoding identity is representation-sensitive" (decoded /= Voting.fromVotingProcedures semantic)
  let indefinite = ByteString.singleton 0xbf <> foldMap pair entries <> ByteString.singleton 0xff
  decodedIndefinite <- expectRight (Voting.decodeCbor indefinite)
  Voting.toVotingProcedures decodedIndefinite @?= semantic
  Voting.toCbor decodedIndefinite @?= indefinite

checkCollections :: IO ()
checkCollections = do
  voters <- votersWith 0
  action <- actionWith 0 0
  forM_ voters $ \voter -> do
    let procedure = Voting.VotingProcedure Voting.Yes Nothing
        triple = (voter, action, procedure)
        one = Voting.singleton voter action procedure
        voterBytes = Voting.encodeVoter voter
        entry = ActionId.encodeCbor action <> Voting.encodeProcedure procedure
        inner = ByteString.singleton 0xa1 <> entry
    Voting.fromList [triple, triple] @?= Left DuplicateGovernanceVote
    Voting.insert voter action (Voting.VotingProcedure Voting.No Nothing) one @?= Left DuplicateGovernanceVote
    Voting.merge one one @?= Left DuplicateGovernanceVote
    Voting.lookup voter action one @?= Just procedure
    Voting.lookup voter action Voting.empty @?= Nothing
    forM_ [ByteString.singleton 0xa1 <> voterBytes <> ByteString.singleton 0xa0, ByteString.singleton 0xa1 <> voterBytes <> ByteString.singleton 0xa2 <> entry <> entry, ByteString.singleton 0xa2 <> voterBytes <> inner <> voterBytes <> inner] $ \encoded ->
      assertBool "nonrepresentable maps rejected" (isLeft (Voting.decodeCbor encoded))
  Voting.encodeCbor Voting.empty @?= ByteString.singleton 0xa0
  Voting.toVotingProcedures <$> Voting.decodeCbor (ByteString.singleton 0xa0) @?= Right Voting.empty

checkRepeated :: IO ()
checkRepeated = do
  value <- pinnedVoting
  let encoded = Voting.encodeCbor value
  replicateM_ 64 (nativeAgreement 5 encoded)
  Voting.encodeCbor value @?= encoded

propRoundTrip :: Property
propRoundTrip = property $ do
  hashBytes <- forAll (Gen.bytes (Range.singleton 28))
  transactionBytes <- forAll (Gen.bytes (Range.singleton 32))
  actionIndex <- forAll (Gen.word64 Range.constantBounded)
  choice <- forAll (Gen.element [Voting.No, Voting.Yes, Voting.Abstain])
  withAnchor <- forAll Gen.bool
  locationText <- forAll (Gen.text (Range.linear 1 128) (Gen.element ['a', 'b', ':', '/']))
  location <- evalEither (Anchor.mkUrl locationText)
  digest <- evalEither (Anchor.dataHashFromBytes transactionBytes)
  transaction <- evalEither (TransactionId.fromBytes transactionBytes)
  hot <- evalEither (Credential.keyHashFromBytes hashBytes)
  drep <- evalEither (Credential.keyHashFromBytes hashBytes)
  pool <- evalEither (Credential.keyHashFromBytes hashBytes)
  script <- evalEither (Credential.scriptHashFromBytes hashBytes)
  let action = ActionId.ActionId transaction actionIndex
      explanation = Anchor.Anchor location digest
      procedure = Voting.VotingProcedure choice (if withAnchor then Just explanation else Nothing)
      voters = [Voting.CommitteeVoter (Credential.KeyCredential hot), Voting.CommitteeVoter (Credential.ScriptCredential script), Voting.DRepVoter (Credential.KeyCredential drep), Voting.DRepVoter (Credential.ScriptCredential script), Voting.StakePoolVoter pool]
  value <- evalEither (Voting.fromList [(voter, action, procedure) | voter <- reverse voters])
  decoded <- evalEither (Voting.decodeCbor (Voting.encodeCbor value))
  Voting.toVotingProcedures decoded === value
  Anchor.decodeCbor (Anchor.encodeCbor explanation) === Right explanation
  ActionId.decodeCbor (ActionId.encodeCbor action) === Right action
  Voting.decodeProcedure (Voting.encodeProcedure procedure) === Right procedure
  forM_ voters $ \voter -> do
    Voting.decodeVoter (Voting.encodeVoter voter) === Right voter
    evalIO (nativeAgreement 3 (Voting.encodeVoter voter))
  forM_ [DRep.DRepCredential (Credential.KeyCredential drep), DRep.DRepCredential (Credential.ScriptCredential script), DRep.AlwaysAbstain, DRep.AlwaysNoConfidence] $ \target -> do
    DRep.decodeCbor (DRep.encodeCbor target) === Right target
    evalIO (nativeAgreement 2 (DRep.encodeCbor target))
  evalIO (nativeAgreement 0 (Anchor.encodeCbor explanation))
  evalIO (nativeAgreement 1 (ActionId.encodeCbor action))
  evalIO (nativeAgreement 4 (Voting.encodeProcedure procedure))
  evalIO (nativeAgreement 5 (Voting.encodeCbor value))

propMerge :: Property
propMerge = property $ do
  hashBytes <- forAll (Gen.bytes (Range.singleton 28))
  transactionBytes <- forAll (Gen.bytes (Range.singleton 32))
  actionIndex <- forAll (Gen.word64 Range.constantBounded)
  key <- evalEither (Credential.keyHashFromBytes hashBytes)
  transaction <- evalEither (TransactionId.fromBytes transactionBytes)
  let voter = Voting.DRepVoter (Credential.KeyCredential key)
      action = ActionId.ActionId transaction actionIndex
      left = Voting.singleton voter action (Voting.VotingProcedure Voting.Yes Nothing)
      middle = Voting.singleton voter (ActionId.ActionId transaction (actionIndex + 1)) (Voting.VotingProcedure Voting.No Nothing)
      right = Voting.singleton voter (ActionId.ActionId transaction (actionIndex + 2)) (Voting.VotingProcedure Voting.Abstain Nothing)
  Voting.merge left Voting.empty === Right left
  Voting.merge Voting.empty left === Right left
  Voting.merge left middle === Voting.merge middle left
  (Voting.merge left middle >>= (`Voting.merge` right)) === (Voting.merge middle right >>= Voting.merge left)

nativeAgreement :: CUInt -> ByteString -> IO ()
nativeAgreement mode encoded = ByteString.useAsCStringLen encoded $ \(input, size) -> do
  agrees <- cAgreement mode (castPtr input) (fromIntegral size)
  agrees @?= 1

bytes :: String -> IO ByteString
bytes encoded = case Hex.decodeHex (Text.pack encoded) of
  Nothing -> assertFailure "invalid fixture hexadecimal" >> fail "unreachable assertion"
  Just value -> pure value

expectRight :: (Show failure) => Either failure value -> IO value
expectRight result = case result of
  Left failure -> assertFailure (show failure) >> fail "unreachable assertion"
  Right value -> pure value

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_governance_agreement"
  cAgreement :: CUInt -> Ptr Word8 -> CSize -> IO CInt

checkActionText :: IO ()
checkActionText = do
  forM_ [0, 1, 255] $ \actionIndex -> do
    action <- actionWith 7 actionIndex
    encoded <- expectRight (ActionId.toText action)
    ActionId.fromText encoded @?= Right action
    ActionId.fromText (Text.toUpper encoded) @?= Right action
    ByteString.useAsCString (TransactionId.toBytes (ActionId.transactionId action)) $ \hash ->
      ByteString.useAsCStringLen (Text.encodeUtf8 encoded) $ \(textPtr, size) -> do
        agrees <- cActionText (castPtr hash) (fromIntegral actionIndex) textPtr (fromIntegral size)
        agrees @?= 1
  forM_ [256, 65535, maxBound] $ \actionIndex -> do
    action <- actionWith 0 actionIndex
    ActionId.toText action @?= Left (InvalidGovernanceActionTextIndex actionIndex)
    ActionId.decodeCbor (ActionId.encodeCbor action) @?= Right action
  prefix <- expectRight (Bech32.humanReadablePartFromText "gov_action")
  wrongPrefix <- expectRight (Bech32.humanReadablePartFromText "stake")
  let invalidPayload size = Bech32.encodeLenient prefix (Bech32.dataPartFromBytes (ByteString.replicate size 0))
  forM_ ["", "gov_action1invalid", invalidPayload 32, invalidPayload 34, Bech32.encodeLenient wrongPrefix (Bech32.dataPartFromBytes (ByteString.replicate 33 0))] $ \encoded ->
    assertBool "reject malformed action identity" (isLeft (ActionId.fromText encoded))
  action <- actionWith 0 0
  encoded <- expectRight (ActionId.toText action)
  assertBool "checksum alteration" (isLeft (ActionId.fromText (Text.init encoded <> if Text.last encoded == 'q' then "p" else "q")))
  assertBool "mixed case" (isLeft (ActionId.fromText ("G" <> Text.drop 1 encoded)))

foreign import ccall safe "cometa_test_action_text"
  cActionText :: Ptr Word8 -> Word8 -> Ptr CChar -> CSize -> IO CInt

checkDRepText :: IO ()
checkDRepText = do
  let hash = ByteString.replicate 28 0xab
  key <- Credential.KeyCredential <$> expectRight (Credential.keyHashFromBytes hash)
  script <- Credential.ScriptCredential <$> expectRight (Credential.scriptHashFromBytes hash)
  forM_ [(False, key, "drep"), (True, script, "drep_script")] $ \(isScript, credential, legacyPrefix) -> do
    let drep = DRep.DRepCredential credential
    canonical <- expectRight (DRep.toText drep)
    DRep.fromText canonical @?= Right drep
    DRep.fromText (Text.toUpper canonical) @?= Right drep
    prefix <- expectRight (Bech32.humanReadablePartFromText legacyPrefix)
    let legacy = Bech32.encodeLenient prefix (Bech32.dataPartFromBytes hash)
    DRep.fromText legacy @?= Right drep
    forM_ [(True, canonical), (False, legacy)] $ \(isCanonical, encoded) ->
      ByteString.useAsCString hash $ \hashPtr ->
        ByteString.useAsCStringLen (Text.encodeUtf8 encoded) $ \(textPtr, size) -> do
          agrees <- cDRepText (castPtr hashPtr) (if isScript then 1 else 0) textPtr (fromIntegral size) (if isCanonical then 1 else 0)
          agrees @?= 1
  forM_ [DRep.AlwaysAbstain, DRep.AlwaysNoConfidence] $ \drep -> assertBool "special targets have no credential identifier" (isLeft (DRep.toText drep))
  prefix <- expectRight (Bech32.humanReadablePartFromText "drep")
  lookalike <- expectRight (Bech32.humanReadablePartFromText "drep_extra")
  let encoded payload = Bech32.encodeLenient prefix (Bech32.dataPartFromBytes payload)
  forM_ ["", "drep1bad", encoded (ByteString.replicate 27 0), encoded (ByteString.replicate 30 0), encoded (ByteString.cons 0x12 hash), encoded (ByteString.cons 0x24 hash), Bech32.encodeLenient lookalike (Bech32.dataPartFromBytes hash)] $ \text ->
    assertBool "invalid DRep prefix/header/checksum/length" (isLeft (DRep.fromText text))

foreign import ccall safe "cometa_test_drep_text"
  cDRepText :: Ptr Word8 -> CInt -> Ptr CChar -> CSize -> CInt -> IO CInt
