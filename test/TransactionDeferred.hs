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

-- These equations intentionally retain both sides of the advertised laws.
{- HLINT ignore "Functor law" -}
{- HLINT ignore "Use <$>" -}
{- HLINT ignore "Monad law, left identity" -}
{- HLINT ignore "Monad law, right identity" -}
{- HLINT ignore "Use >=>" -}
module TransactionDeferred (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (InvalidBuildingRequest))
import Cometa.Evaluation (RedeemerId (..))
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.ExUnits as ExUnits
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Deferred as Deferred
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Indices as Indices
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Value
import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Word (Word64)
import qualified Hedgehog as H
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Deferred redeemer queries"
    [ testCase "required indices match ordinary draft observers" indices,
      testCase "missing objects and ambiguous outputs fail explicitly" failures,
      testCase "callback adapters match raw callbacks and retain exact data" callbacks,
      testProperty "Functor, Applicative and Monad laws share one draft" laws
    ]

must :: (Show error) => Either error value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

data Fixture = Fixture
  { fixtureTransaction :: Tx.Transaction,
    fixtureSelected :: [Utxo.Utxo],
    fixtureOutput :: Output.Output,
    fixtureReference :: Input.Input,
    fixturePolicy :: Policy.PolicyId,
    fixtureAccount :: Reward.RewardAddress,
    fixtureVoter :: Voting.Voter,
    fixtureProposal :: Proposal.Proposal
  }

fixture :: IO Fixture
fixture = do
  hash <- must (Credential.keyHashFromBytes (B.replicate 28 1))
  payment <- must (Credential.keyHashFromBytes (B.replicate 28 1))
  drep <- must (Credential.keyHashFromBytes (B.replicate 28 2))
  txid <- must (TxId.fromBytes (B.replicate 32 3))
  policy <- must (Policy.fromBytes (B.replicate 28 4))
  assetName <- must (AssetName.fromBytes B.empty)
  url <- must (Anchor.mkUrl "https://example.com/proposal")
  digest <- must (Anchor.dataHashFromBytes (B.replicate 32 5))
  let account = Reward.fromCredential Network.testnet (Credential.KeyCredential hash)
      address = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential payment))
      reference = Input.input txid 7
      later = Input.input txid 256
      voter = Voting.DRepVoter (Credential.KeyCredential drep)
      anchor = Anchor.Anchor url digest
      proposal = Proposal.Proposal 1 account Action.InfoAction anchor
      votes = Voting.singleton voter (ActionId.ActionId txid 0) (Voting.VotingProcedure Voting.Yes Nothing)
  output <- must (Output.mkOutput address (Value.lovelace 2000000) Datum.NoDatum Nothing)
  withdrawals <- must (Fields.mkEntries [(account, 0)])
  mint <- must (Fields.mkMint (Value.fromList [(Asset.Native policy assetName, 1)]))
  let proposals = Proposal.fromList [proposal]
  let fields =
        (Fields.fields [later, reference] [output])
          { Fields.fieldReferenceInputs = Just [later, reference],
            Fields.fieldMint = Just mint,
            Fields.fieldWithdrawals = Just withdrawals,
            Fields.fieldVotingProcedures = Just votes,
            Fields.fieldProposalProcedures = Just proposals
          }
      dataValue = Data.fromData (Data.Integer 1)
      redeemer = Redeemer.Redeemer Redeemer.Spending 0 dataValue (ExUnits.ExUnits 0 0)
  body <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = fields}))
  witnesses <- must (Witnesses.mkWitnesses [] [] [] [] [redeemer])
  pure (Fixture (Tx.assemble body (Witnesses.fromWitnesses witnesses) Nothing) [Utxo.utxo reference output] output reference policy account voter proposal)

indices :: IO ()
indices = do
  f <- fixture
  let tx = fixtureTransaction f
      run query = Deferred.run query tx (fixtureSelected f)
      cases =
        [ (Deferred.inputIndex (fixtureReference f), Indices.findInput (fixtureReference f) tx),
          (Deferred.referenceInputIndex (fixtureReference f), Indices.findReferenceInput (fixtureReference f) tx),
          (Deferred.mintPolicyIndex (fixturePolicy f), Indices.findMintPolicy (fixturePolicy f) tx),
          (Deferred.withdrawalIndex (fixtureAccount f), Indices.findWithdrawal (fixtureAccount f) tx),
          (Deferred.voteIndex (fixtureVoter f), Indices.findVote (fixtureVoter f) tx),
          (Deferred.proposalIndex (fixtureProposal f), Indices.findProposal (fixtureProposal f) tx),
          (Deferred.redeemerIndex (RedeemerId Redeemer.Spending 0), Indices.findRedeemer (RedeemerId Redeemer.Spending 0) tx)
        ]
  forM_ cases $ \(query, ordinary) -> do
    ordinary @?= Just 0
    run query @?= Right 0
  run (Deferred.outputIndex (fixtureOutput f)) @?= Right 0
  run (Deferred.outputIndexWhere ((== Output.address (fixtureOutput f)) . Output.address)) @?= Right 0
  fmap Tx.encodeCbor (run Deferred.draft) @?= Right (Tx.encodeCbor tx)
  run Deferred.selectedInputs @?= Right (fixtureSelected f)
  Deferred.run Deferred.selectedInputs tx (reverse (fixtureSelected f <> fixtureSelected f)) @?= Right (reverse (fixtureSelected f <> fixtureSelected f))

failures :: IO ()
failures = do
  f <- fixture
  body <- must (Body.fromBody (Body.body [] [] 0))
  let empty = Tx.fromBody body
      queries =
        [ Deferred.inputIndex (fixtureReference f),
          Deferred.referenceInputIndex (fixtureReference f),
          Deferred.mintPolicyIndex (fixturePolicy f),
          Deferred.withdrawalIndex (fixtureAccount f),
          Deferred.voteIndex (fixtureVoter f),
          Deferred.proposalIndex (fixtureProposal f),
          Deferred.redeemerIndex (RedeemerId Redeemer.Spending 0),
          Deferred.outputIndex (fixtureOutput f)
        ]
  forM_ queries $ \query -> assertBool "Missing index succeeded" (isLeft (Deferred.run query empty []))
  Deferred.run (Deferred.outputIndex (fixtureOutput f)) empty [] @?= Left (InvalidBuildingRequest "Deferred output is missing")
  duplicateBody <- must (Body.fromBody (Body.body [] [fixtureOutput f, fixtureOutput f] 0))
  Deferred.run (Deferred.outputIndex (fixtureOutput f)) (Tx.fromBody duplicateBody) [] @?= Left (InvalidBuildingRequest "Deferred output is ambiguous")
  Deferred.run (Deferred.outputIndexWhere (const True)) (Tx.fromBody duplicateBody) [] @?= Left (InvalidBuildingRequest "Deferred output is ambiguous")
  let failure = InvalidBuildingRequest "application validation"
  Deferred.run (Deferred.fromEither (Left failure) >> Deferred.inputIndex (fixtureReference f)) empty [] @?= Left failure

callbacks :: IO ()
callbacks = do
  f <- fixture
  let query = (,) <$> Deferred.inputIndex (fixtureReference f) <*> Deferred.outputIndex (fixtureOutput f)
      encode :: (Word64, Word64) -> Data.PlutusData
      encode (input, output) = Data.List [Data.Integer (toInteger input), Data.Integer (toInteger output)]
      callback :: Plan.DeferredRedeemer
      callback = Deferred.redeemer encode query
      subCallback :: SubPlan.DeferredRedeemer
      subCallback = callback
      raw tx _ = do
        input <- maybe (Left (InvalidBuildingRequest "raw input missing")) Right (Indices.findInput (fixtureReference f) tx)
        pure (Data.fromData (encode (input, 0)))
  callback (fixtureTransaction f) (fixtureSelected f) @?= raw (fixtureTransaction f) (fixtureSelected f)
  subCallback (fixtureTransaction f) (fixtureSelected f) @?= callback (fixtureTransaction f) (fixtureSelected f)
  -- Each callback reads its new draft; previously observed positions are not cached.
  let originalBody = Body.toBody (Tx.body (fixtureTransaction f))
      originalFields = Body.bodyFields originalBody
      preceding = Input.input (Input.transactionId (fixtureReference f)) 0
      changedFields = originalFields {Fields.fieldInputs = preceding : Fields.fieldInputs originalFields}
  changedBody <- must (Body.fromBody (originalBody {Body.bodyFields = changedFields}))
  let changed = Tx.fromBody changedBody
  callback changed (fixtureSelected f) @?= Right (Data.fromData (encode (1, 0)))
  callback (fixtureTransaction f) (fixtureSelected f) @?= Right (Data.fromData (encode (0, 0)))
  -- Nonminimal integer encoding remains exact through encodedRedeemer.
  exact <- must (Data.decodeCbor (B.pack [0x18, 0x01]))
  fmap Data.toCbor (Deferred.encodedRedeemer (pure exact) (fixtureTransaction f) (fixtureSelected f)) @?= Right (B.pack [0x18, 0x01])
  let failure = InvalidBuildingRequest "application failure"
  Deferred.redeemer Data.Integer (Deferred.fromEither (Left failure)) (fixtureTransaction f) [] @?= Left failure

laws :: H.Property
laws = H.property $ do
  f <- H.evalIO fixture
  value <- H.forAll (Gen.integral (Range.linear (-100) 100) :: H.Gen Integer)
  fails <- H.forAll Gen.bool
  let run computation = Deferred.run computation (fixtureTransaction f) (fixtureSelected f)
      query = if fails then Deferred.fromEither (Left (InvalidBuildingRequest "law failure")) else (+ value) . toInteger <$> Deferred.inputIndex (fixtureReference f)
      step number = if even number then pure (number + 3) else Deferred.fromEither (Left (InvalidBuildingRequest "odd"))
      next number = (+ number) . toInteger <$> Deferred.outputIndex (fixtureOutput f)
  run (fmap id query) H.=== run query
  run (fmap ((+ 1) . (* 2)) query) H.=== run (fmap (+ 1) (fmap (* 2) query))
  run (pure id <*> query) H.=== run query
  run (pure (+ 1) <*> pure value) H.=== Right (value + 1)
  run (pure (.) <*> pure (+ 1) <*> pure (* 2) <*> query) H.=== run (pure (+ 1) <*> (pure (* 2) <*> query))
  run (pure (+ 1) <*> pure value) H.=== run (pure ($ value) <*> pure (+ 1))
  run (pure value >>= step) H.=== run (step value)
  run (query >>= pure) H.=== run query
  run ((query >>= step) >>= next) H.=== run (query >>= (\number -> step number >>= next))
