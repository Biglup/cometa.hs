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

-- | Independent accounting equations exercised through native building calls.
-- Primary-source provenance and limits: Fixtures/TRANSACTION_ACCOUNTING.md.
module TransactionAccountingProperties (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as Name
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import Cometa.Encoding.Set (SetEncoding (..))
import Cometa.Error (Error)
import qualified Cometa.Governance.Action as Action
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Proposal as Proposal
import qualified Cometa.NetworkId as Network
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.UnitInterval as Unit
import qualified Cometa.Value as Value
import Control.Monad (forM_, when)
import qualified Data.ByteString as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64, Word8)
import qualified Fixtures.ProtocolParameters as ProtocolFixture
import Hedgehog (Gen, Property, PropertyT, classify, evalEither, evalIO, forAll, property, withTests, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

-- TYPES ----------------------------------------------------------------------

data Event
  = LegacyRegistration
  | LegacyDeregistration
  | Registration Word64
  | Unregistration Word64
  | DRepRegistration Word64
  | DRepUnregistration Word64
  | StakeRegistrationDelegation Word64
  | VoteRegistrationDelegation Word64
  | StakeVoteRegistrationDelegation Word64
  | Retirement
  deriving (Eq, Show)

data Fixture = Fixture
  { fixtureAddress :: Address.Address,
    fixtureStake :: Credential.Credential Credential.Stake,
    fixtureDRep :: Credential.Credential Credential.DRep,
    fixturePool :: Credential.KeyHash Credential.StakePool,
    fixtureAccount :: Reward.RewardAddress,
    fixtureAnchor :: Anchor.Anchor
  }

data Scenario = Scenario
  { scenarioWithdrawal :: Word64,
    scenarioDeposit :: Word64,
    scenarioRefund :: Word64,
    scenarioDonation :: Word64,
    scenarioDirectDeposit :: Word64,
    scenarioFee :: Word64,
    scenarioMint :: Integer,
    scenarioPerturbation :: Integer
  }
  deriving (Show)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Native transaction accounting properties"
    [ testProperty "mixed implicit deposits, refunds and withdrawals follow independent totals" propImplicit,
      testProperty "top-level, local and batch conservation includes signed mint and account flows" propConservation,
      testProperty "zero mint is absent in the shrunk accounting regression" zeroMintRegression,
      testProperty "pool deposit deduplication is local and global at the appropriate scope" propPoolDeposits
    ]

smallAmount :: Gen Word64
smallAmount = Gen.choice [Gen.element [0, 1, 23, 24, 255, 256, 65535, 65536], Gen.integral (Range.linear 0 1000000)]

genEvent :: Gen Event
genEvent =
  Gen.choice
    [ pure LegacyRegistration,
      pure LegacyDeregistration,
      Registration <$> smallAmount,
      Unregistration <$> smallAmount,
      DRepRegistration <$> smallAmount,
      DRepUnregistration <$> smallAmount,
      StakeRegistrationDelegation <$> smallAmount,
      VoteRegistrationDelegation <$> smallAmount,
      StakeVoteRegistrationDelegation <$> smallAmount,
      pure Retirement
    ]

fixture :: Either Error Fixture
fixture = do
  payment <- Credential.keyHashFromBytes (B.replicate 28 1)
  staking <- Credential.keyHashFromBytes (B.replicate 28 2)
  representative <- Credential.keyHashFromBytes (B.replicate 28 3)
  pool <- Credential.keyHashFromBytes (B.replicate 28 4)
  url <- Anchor.mkUrl "https://example.com/accounting"
  digest <- Anchor.dataHashFromBytes (B.replicate 32 5)
  let stake = Credential.KeyCredential staking
  pure (Fixture (Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential payment))) stake (Credential.KeyCredential representative) pool (Reward.fromCredential Network.testnet stake) (Anchor.Anchor url digest))

certificate :: Fixture -> Event -> Certificate.Certificate
certificate f event = case event of
  LegacyRegistration -> Certificate.StakeRegistration (fixtureStake f)
  LegacyDeregistration -> Certificate.StakeDeregistration (fixtureStake f)
  Registration amount -> Certificate.Registration (fixtureStake f) amount
  Unregistration amount -> Certificate.Unregistration (fixtureStake f) amount
  DRepRegistration amount -> Certificate.RegisterDRep (fixtureDRep f) amount Nothing
  DRepUnregistration amount -> Certificate.UnregisterDRep (fixtureDRep f) amount
  StakeRegistrationDelegation amount -> Certificate.StakeRegistrationDelegation (fixtureStake f) (fixturePool f) amount
  VoteRegistrationDelegation amount -> Certificate.VoteRegistrationDelegation (fixtureStake f) DRep.AlwaysAbstain amount
  StakeVoteRegistrationDelegation amount -> Certificate.StakeVoteRegistrationDelegation (fixtureStake f) (fixturePool f) DRep.AlwaysAbstain amount
  Retirement -> Certificate.PoolRetirement (fixturePool f) 42

-- These expectations consume generated events, never decoded certificates or
-- native results. All arithmetic remains unbounded until the final comparison.
eventTotals :: Word64 -> [Event] -> (Integer, Integer)
eventTotals keyDeposit events = (sum (map paid events), sum (map refunded events))
  where
    paid event = case event of
      LegacyRegistration -> toInteger keyDeposit
      Registration amount -> toInteger amount
      DRepRegistration amount -> toInteger amount
      StakeRegistrationDelegation amount -> toInteger amount
      VoteRegistrationDelegation amount -> toInteger amount
      StakeVoteRegistrationDelegation amount -> toInteger amount
      _ -> 0
    refunded event = case event of
      LegacyDeregistration -> toInteger keyDeposit
      Unregistration amount -> toInteger amount
      DRepUnregistration amount -> toInteger amount
      _ -> 0

withdrawalEntries :: [Word64] -> Either Error (Fields.Entries Reward.RewardAddress Word64)
withdrawalEntries amounts = do
  accounts <- traverse account [1 .. length amounts]
  Fields.mkEntries (zip accounts amounts)
  where
    account index = Reward.fromCredential Network.testnet . Credential.KeyCredential <$> Credential.keyHashFromBytes (B.replicate 28 (fromIntegral index))

propImplicit :: Property
propImplicit = property $ do
  events <- forAll (Gen.list (Range.linear 0 20) genEvent)
  proposals <- forAll (Gen.list (Range.linear 0 6) smallAmount)
  withdrawals <- forAll (Gen.list (Range.linear 1 5) smallAmount)
  keyDeposit <- forAll smallAmount
  f <- evalEither fixture
  raw <- evalEither ProtocolFixture.parameters
  entries <- evalEither (withdrawalEntries withdrawals)
  let parameters = raw {Parameters.parameterKeyDeposit = keyDeposit}
      (paid, refunded) = eventTotals keyDeposit events
      expected = Building.ImplicitCoin (fromInteger (sum (map toInteger withdrawals))) (fromInteger (paid + sum (map toInteger proposals))) (fromInteger refunded)
      fields =
        (Fields.fields [] [])
          { Fields.fieldCertificates = Just (Certificates.fromList (map (certificate f) events)),
            Fields.fieldProposalProcedures = Just (Proposal.fromList [Proposal.Proposal amount (fixtureAccount f) Action.InfoAction (fixtureAnchor f) | amount <- proposals]),
            Fields.fieldWithdrawals = Just entries
          }
      -- Top-level empty collections are representable; the subtransaction
      -- grammar requires those optional fields to be absent when empty.
      localFields =
        fields
          { Fields.fieldCertificates = if null events then Nothing else Fields.fieldCertificates fields,
            Fields.fieldProposalProcedures = if null proposals then Nothing else Fields.fieldProposalProcedures fields
          }
  classify "legacy deposits/refunds" (LegacyRegistration `elem` events || LegacyDeregistration `elem` events)
  classify "governance proposal deposits" (not (null proposals))
  classify "retirement has no immediate refund" (Retirement `elem` events)
  forM_ [TaggedSet, UntaggedSet] $ \encoding -> do
    bodyBytes <- evalEither (Body.encodeCborWith encoding ((Body.body [] [] 0) {Body.bodyFields = fields}))
    encodedBody <- evalEither (Body.decodeCbor bodyBytes)
    let transaction = Tx.fromBody encodedBody
        before = Tx.encodeCbor transaction
    actual <- evalIO (Building.implicitCoin parameters transaction) >>= evalEither
    actual === expected
    localBytes <- evalEither (SubBody.encodeCborWith encoding (SubBody.fromFields localFields))
    localBody <- evalEither (SubBody.decodeCbor localBytes)
    local <- evalIO (Building.subTransactionImplicitCoin parameters (Sub.fromBody localBody)) >>= evalEither
    local === expected
    Tx.encodeCbor transaction === before

scenario :: Gen Scenario
scenario = Scenario <$> smallAmount <*> smallAmount <*> smallAmount <*> smallAmount <*> smallAmount <*> smallAmount <*> Gen.integral (Range.linear (-1000) 1000) <*> Gen.element [-100, 0, 100]

-- A generated perturbation changes both coin and one asset's outputs. Zero is
-- exactly balanced; the other choices are deliberate componentwise deficits or
-- surpluses. Burn shrinkage cannot make outputs negative because funding is ample.
scenarioFields :: Fixture -> Word8 -> Word64 -> Scenario -> Either Error (Fields.Fields, Utxo.Utxo, Map Asset.AssetId Integer)
scenarioFields f salt chargedFee value = do
  policy <- Policy.fromBytes (B.replicate 28 37)
  identifier <- Id.fromBytes (B.replicate 32 salt)
  let asset = Asset.Native policy Name.empty
      perturbation = scenarioPerturbation value
      inputCoin = 2000000000
      outputCoin = inputCoin + toInteger (scenarioWithdrawal value) + toInteger (scenarioRefund value) - toInteger (scenarioDeposit value) - toInteger chargedFee - toInteger (scenarioDonation value) - toInteger (scenarioDirectDeposit value) + perturbation
      tokenSupply = 10000
      tokenOutput = tokenSupply + scenarioMint value + perturbation
      inputReference = Input.input identifier 0
  funding <- Output.mkOutput (fixtureAddress f) (Value.fromList [(Asset.Ada, inputCoin), (asset, tokenSupply)]) Datum.NoDatum Nothing
  output <- Output.mkOutput (fixtureAddress f) (Value.fromList [(Asset.Ada, outputCoin), (asset, tokenOutput)]) Datum.NoDatum Nothing
  mint <- Fields.mkMint (Value.singleton asset (scenarioMint value))
  withdrawals <- Fields.mkEntries [(fixtureAccount f, scenarioWithdrawal value)]
  direct <- Fields.mkEntries [(fixtureAccount f, scenarioDirectDeposit value)]
  let fields =
        (Fields.fields [inputReference] [output])
          { Fields.fieldMint = if scenarioMint value == 0 then Nothing else Just mint,
            Fields.fieldWithdrawals = Just withdrawals,
            Fields.fieldDirectDeposits = Just direct,
            Fields.fieldDonation = Just (scenarioDonation value),
            Fields.fieldCertificates = Just (Certificates.fromList [Certificate.Registration (fixtureStake f) (scenarioDeposit value), Certificate.Unregistration (fixtureStake f) (scenarioRefund value)])
          }
      expected = Map.fromList [(Asset.Ada, negate perturbation), (asset, negate perturbation)]
  pure (fields, Utxo.utxo inputReference funding, normalize expected)

normalize :: Map Asset.AssetId Integer -> Map Asset.AssetId Integer
normalize = Map.filter (/= 0)

observed :: Value.Value -> Map Asset.AssetId Integer
observed = Map.fromList . Value.toList

propConservation :: Property
propConservation = property $ do
  outerCase <- forAll scenario
  localCase <- forAll scenario
  checkConservation outerCase localCase

-- The CI failure shrank to zero local mint and a top-level burn. Retain this
-- exact case independently of random seeds, then cover zero at either level.
zeroMintRegression :: Property
zeroMintRegression = withTests 1 . property $ do
  let zero = Scenario 0 0 0 0 0 0 0 (-100)
  checkConservation zero {scenarioMint = -1000} zero
  forM_ [-1, 0, 1] $ \amount -> do
    checkConservation zero {scenarioMint = amount} zero
    checkConservation zero zero {scenarioMint = amount}

checkConservation :: Scenario -> Scenario -> PropertyT IO ()
checkConservation outerCase localCase = do
  f <- evalEither fixture
  parameters <- evalEither ProtocolFixture.parameters
  (outerFields, outerInput, outerExpected) <- evalEither (scenarioFields f 17 (scenarioFee outerCase) outerCase)
  (localFields, localInput, localExpected) <- evalEither (scenarioFields f 18 0 localCase)
  when (scenarioMint localCase == 0) $ Fields.fieldMint localFields === Nothing
  extraIdentifier <- evalEither (Id.fromBytes (B.replicate 32 19))
  let extra = Utxo.utxo (Input.input extraIdentifier 0) (Utxo.output outerInput)
      expected = normalize (Map.unionWith (+) outerExpected localExpected)
      resolved = [localInput, extra, outerInput]
  classify "minting" (scenarioMint outerCase > 0 || scenarioMint localCase > 0)
  classify "burning" (scenarioMint outerCase < 0 || scenarioMint localCase < 0)
  classify "complete balance" (Map.null expected)
  classify "opposing intent imbalances cancel" (scenarioPerturbation outerCase /= 0 && scenarioPerturbation outerCase == negate (scenarioPerturbation localCase))
  classify "coin surplus" (Map.findWithDefault 0 Asset.Ada expected > 0)
  classify "coin deficit" (Map.findWithDefault 0 Asset.Ada expected < 0)
  forM_ [TaggedSet, UntaggedSet] $ \encoding -> do
    localBytes <- evalEither (SubBody.encodeCborWith encoding (SubBody.fromFields (localFields {Fields.fieldReferenceInputs = Just [Utxo.input extra]})))
    localBody <- evalEither (SubBody.decodeCbor localBytes)
    let local = Sub.fromBody localBody
        outer = (Body.body [] [] (scenarioFee outerCase)) {Body.bodyFields = outerFields {Fields.fieldReferenceInputs = Just [Utxo.input extra]}, Body.bodyCollateral = Just [Utxo.input extra], Body.bodySubTransactions = Just [local]}
    bytes <- evalEither (Body.encodeCborWith encoding outer)
    body <- evalEither (Body.decodeCbor bytes)
    let transaction = Tx.fromBody body
        before = Tx.encodeCbor transaction
    top <- evalIO (Building.imbalance parameters resolved transaction) >>= evalEither
    observed top === outerExpected
    sub <- evalIO (Building.subTransactionImbalance parameters resolved local) >>= evalEither
    observed sub === localExpected
    batch <- evalIO (Building.batchImbalance parameters resolved transaction) >>= evalEither
    observed batch === expected
    balanced <- evalIO (Building.isBalanced parameters resolved transaction) >>= evalEither
    balanced === Map.null expected
    Tx.encodeCbor transaction === before

poolParameters :: Fixture -> Word8 -> Either Error Pool.PoolParameters
poolParameters f identifier = do
  operator <- Credential.keyHashFromBytes (B.replicate 28 identifier)
  vrf <- Pool.vrfKeyHashFromBytes (B.replicate 32 identifier)
  margin <- Unit.mkUnitInterval 0 1
  pure (Pool.PoolParameters operator vrf Nothing 0 0 margin (fixtureAccount f) Set.empty [] Nothing)

propPoolDeposits :: Property
propPoolDeposits = property $ do
  outerPools <- forAll (Gen.list (Range.linear 1 8) (Gen.integral (Range.linear 1 4)))
  localPools <- forAll (Gen.list (Range.linear 1 8) (Gen.integral (Range.linear 1 4)))
  deposit <- forAll smallAmount
  f <- evalEither fixture
  raw <- evalEither ProtocolFixture.parameters
  outerParameters <- evalEither (traverse (poolParameters f) outerPools)
  localParameters <- evalEither (traverse (poolParameters f) localPools)
  let parameters = raw {Parameters.parameterPoolDeposit = deposit}
      fields values = (Fields.fields [] []) {Fields.fieldCertificates = Just (Certificates.fromList (map Certificate.PoolRegistration values))}
      outerCount = toInteger (Set.size (Set.fromList outerPools))
      localCount = toInteger (Set.size (Set.fromList localPools))
      totalCount = toInteger (Set.size (Set.fromList (outerPools <> localPools)))
      paid count = count * toInteger deposit
  classify "within-body repeat" (length outerPools > Set.size (Set.fromList outerPools))
  classify "cross-body repeat" (outerCount + localCount > totalCount)
  localBody <- evalEither (SubBody.fromBody (SubBody.fromFields (fields localParameters)))
  let local = Sub.fromBody localBody
  encoded <- evalEither (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = fields outerParameters, Body.bodySubTransactions = Just [local]}))
  let transaction = Tx.fromBody encoded
  top <- evalIO (Building.implicitCoin parameters transaction) >>= evalEither
  top === Building.ImplicitCoin 0 (fromInteger (paid outerCount)) 0
  sub <- evalIO (Building.subTransactionImplicitCoin parameters local) >>= evalEither
  sub === Building.ImplicitCoin 0 (fromInteger (paid localCount)) 0
  batch <- evalIO (Building.batchImbalance parameters [] transaction) >>= evalEither
  observed batch === normalize (Map.singleton Asset.Ada (negate (paid totalCount)))
