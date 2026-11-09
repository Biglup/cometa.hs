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

-- | Original properties for fee and pool-accounting gaps. Independent numeric
-- expectations come from generated descriptions, not native fee/accounting
-- results. Source revision/path/license review: Fixtures/ACCOUNTING_RELIABILITY.md.
module AccountingReliability (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.PublicKey as Key
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import Cometa.Error (Error)
import qualified Cometa.Metadata as Metadata
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as Ex
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Script as Script
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.AuxiliaryData as Auxiliary
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as Id
import qualified Cometa.UnitInterval as Unit
import qualified Cometa.Value as Value
import Control.Monad (forM)
import qualified Data.ByteString as B
import Data.Ratio ((%))
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Word (Word64, Word8)
import qualified Fixtures.ProtocolParameters as ProtocolFixture
import Hedgehog (Gen, Property, PropertyT, classify, evalEither, evalIO, forAll, property, withTests, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

-- TYPES ----------------------------------------------------------------------

data PoolEvent = Register Word8 | Retire Word8 deriving (Eq, Show)

type Budget = (Word64, Word64)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Independent accounting reliability"
    [ testProperty "linear fees use the three-part ledger envelope across witness width boundaries" propLinearFee,
      testProperty "reference pricing follows marginal byte rates and ignores script partitioning" propReferenceTiers,
      testProperty "native batch execution charges aggregate all intents before rounding once" propExecutionRounding,
      testProperty "split half-unit execution charges round once in the complete native fee" halfUnitRegression,
      testProperty "pool updates and retirements preserve operator deposit identity across many intents" propPoolUpdates
    ]

address :: Either Error Address.Address
address = do
  key <- Credential.keyHashFromBytes (B.replicate 28 9)
  pure (Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key)))

propLinearFee :: Property
propLinearFee = property $ do
  witnessCount <- forAll (Gen.element [0, 1, 2, 22, 23, 24, 25])
  textSize <- forAll (Gen.element [0, 1, 23, 24, 63, 64])
  auxiliaryPresent <- forAll Gen.bool
  coefficient <- forAll (Gen.integral (Range.linear 0 1000))
  constant <- forAll (Gen.integral (Range.linear 0 1000000))
  bodyFee <- forAll (Gen.element [0, 23, 24, 255, 256, 65535, 65536])
  keys <- evalEither $ traverse keyWitness [1 .. witnessCount]
  witnesses <- Witnesses.fromWitnesses <$> evalEither (Witnesses.mkWitnesses keys [] [] [] [])
  text <- evalEither (Metadata.mkText (T.replicate textSize "x"))
  metadata <- evalEither (Metadata.decodeCbor (Metadata.encodeCbor (Metadata.singleton 1 text)))
  let auxiliary = if auxiliaryPresent then Just (Auxiliary.fromAuxiliaryData (Auxiliary.auxiliaryData (Just metadata) Nothing [])) else Nothing
  encoded <- evalEither (Body.fromBody (Body.body [] [] bodyFee))
  let transaction = Tx.assemble encoded witnesses auxiliary
      -- Ledger Alonzo size uses [body,witnesses,auxiliary-or-null]. The list
      -- header is one byte. No full-transaction size or native fee helper is
      -- consulted, and the mempool validity byte never enters this equation.
      ledgerBytes = 1 + B.length (Body.toCbor encoded) + B.length (Witnesses.toCbor witnesses) + maybe 1 (B.length . Auxiliary.toCbor) auxiliary
      expected = toInteger constant + toInteger coefficient * toInteger ledgerBytes
      original = Tx.encodeCbor transaction
  classify "witness collection header grows" (witnessCount >= 24)
  classify "auxiliary field absent" (not auxiliaryPresent)
  actual <- evalIO (Building.baseFee constant coefficient transaction) >>= evalEither
  toInteger actual === expected
  falseFee <- evalIO (Building.baseFee constant coefficient (Tx.setScriptValidity False transaction)) >>= evalEither
  falseFee === actual
  Tx.encodeCbor transaction === original
  where
    keyWitness index = Witness.verificationWitness <$> Key.fromBytes (B.replicate 32 index) <*> Signature.fromBytes (B.replicate 64 index)

propReferenceTiers :: Property
propReferenceTiers = property $ do
  stride <- forAll (Gen.element [1, 2, 5, 23, 24, 64])
  total <- forAll (Gen.element [0, 1, stride - 1, stride, stride + 1, 2 * stride - 1, 2 * stride, 2 * stride + 1, 6 * stride])
  cuts <- forAll (Gen.list (Range.linear 0 3) (Gen.int (Range.linear 0 total)))
  priceNumerator <- forAll (Gen.integral (Range.linear 0 10000))
  priceDenominator <- forAll (Gen.integral (Range.linear 1 19))
  (multiplierNumerator, multiplierDenominator) <- forAll (Gen.element [(1, 2), (1, 1), (3, 2), (6, 5)])
  raw <- evalEither ProtocolFixture.parameters
  strideValue <- evalEither (Parameters.mkReferenceScriptCostStride (toInteger stride))
  price <- evalEither (Rational.mkNonNegativeRational priceNumerator priceDenominator)
  multiplier <- evalEither (Rational.mkNonNegativeRational multiplierNumerator multiplierDenominator)
  destination <- evalEither address
  let points = Set.toAscList (Set.fromList (0 : total : cuts))
      parts = zipWith (-) (drop 1 points) points
      prices = (priceNumerator % priceDenominator, multiplierNumerator % multiplierDenominator)
      -- Assign each byte its independent marginal tier index, then floor the
      -- rational total once. This does not reproduce the production mixed-
      -- number recurrence, coarsening path or fixed-width arithmetic.
      (perByte, growth) = prices
      exact = sum [perByte * growth ^ (byte `quot` stride) | byte <- [0 .. total - 1]]
      expected = floor exact :: Integer
      parameters = raw {Parameters.parameterRefScriptCostPerByte = Just price, Parameters.parameterRefScriptCostStride = Just strideValue, Parameters.parameterRefScriptCostMultiplier = Just multiplier}
  split <- evalEither (traverse (uncurry (referenceUtxo destination)) (zip [1 ..] parts))
  single <- evalEither (if total == 0 then Right [] else (: []) <$> referenceUtxo destination 99 total)
  classify "zero scripts" (total == 0)
  classify "exact tier boundary" (total > 0 && total `rem` stride == 0)
  classify "decreasing marginal prices" (multiplierNumerator < multiplierDenominator)
  classify "partitioned reference payload" (length parts > 1)
  splitFee <- evalIO (Building.referenceScriptFee parameters split) >>= evalEither
  singleFee <- evalIO (Building.referenceScriptFee parameters single) >>= evalEither
  toInteger splitFee === expected
  toInteger singleFee === expected

referenceUtxo :: Address.Address -> Word8 -> Int -> Either Error Utxo.Utxo
referenceUtxo destination salt count = do
  script <- Script.Plutus <$> Plutus.fromBytes Plutus.V2 (B.replicate count salt)
  output <- Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum (Just script)
  identifier <- Id.fromBytes (B.replicate 32 salt)
  pure (Utxo.utxo (Input.input identifier 0) output)

budget :: Gen Budget
budget = (,) <$> Gen.integral (Range.linear 0 1000) <*> Gen.integral (Range.linear 0 1000)

propExecutionRounding :: Property
propExecutionRounding = property $ do
  groups <- forAll (Gen.list (Range.linear 1 5) (Gen.list (Range.linear 0 4) budget))
  memoryNumerator <- forAll (Gen.integral (Range.linear 0 13))
  memoryDenominator <- forAll (Gen.integral (Range.linear 1 17))
  stepNumerator <- forAll (Gen.integral (Range.linear 0 13))
  stepDenominator <- forAll (Gen.integral (Range.linear 1 17))
  checkExecution groups (memoryNumerator, memoryDenominator) (stepNumerator, stepDenominator)

halfUnitRegression :: Property
halfUnitRegression = withTests 1 . property $ checkExecution [[(1, 0)], [(1, 0)], [(1, 0)], [(1, 0)]] (1, 2) (0, 1)

checkExecution :: [[Budget]] -> (Integer, Integer) -> (Integer, Integer) -> PropertyT IO ()
checkExecution groups memoryRate stepRate = do
  raw <- evalEither ProtocolFixture.parameters
  memoryPrice <- evalEither (uncurry Rational.mkNonNegativeRational memoryRate)
  stepPrice <- evalEither (uncurry Rational.mkNonNegativeRational stepRate)
  zero <- evalEither (Rational.mkNonNegativeRational 0 1)
  let charge values = sum [fromIntegral memory * uncurry (%) memoryRate + fromIntegral steps * uncurry (%) stepRate | (memory, steps) <- values]
      expected = ceiling (charge (concat groups)) :: Integer
      separatelyRounded = sum [ceiling (charge values) :: Integer | values <- groups]
      parameters = raw {Parameters.parameterMinFeeA = 0, Parameters.parameterMinFeeB = 0, Parameters.parameterExecutionCosts = Just (Prices.ExUnitPrices memoryPrice stepPrice), Parameters.parameterRefScriptCostPerByte = Just zero}
      (outerBudgets, localBudgets) = case groups of [] -> ([], []); first : rest -> (first, rest)
  outerWitnesses <- evalEither (budgetWitnesses outerBudgets)
  locals <- evalEither $ traverse (uncurry localTransaction) (zip [1 ..] localBudgets)
  encoded <- evalEither (Body.fromBody ((Body.body [] [] 0) {Body.bodySubTransactions = if null locals then Nothing else Just locals}))
  let transaction = Tx.assemble encoded outerWitnesses Nothing
      original = Tx.encodeCbor transaction
  classify "separate intent rounding would overcharge" (separatelyRounded > expected)
  classify "several nested intent budgets" (length localBudgets >= 2)
  actual <- evalIO (Building.minimumFee parameters [] transaction) >>= evalEither
  toInteger actual === expected
  Tx.encodeCbor transaction === original

budgetWitnesses :: [Budget] -> Either Error Witnesses.EncodedWitnesses
budgetWitnesses values = Witnesses.fromWitnesses <$> Witnesses.mkWitnesses [] [] [] [] [Redeemer.Redeemer Redeemer.Spending index argument (Ex.ExUnits memory steps) | (index, (memory, steps)) <- zip [0 ..] values]
  where
    argument = Data.fromData (Data.Integer 0)

localTransaction :: Word64 -> [Budget] -> Either Error Sub.SubTransaction
localTransaction index values = do
  encoded <- SubBody.fromBody (SubBody.fromFields ((Fields.fields [] []) {Fields.fieldInvalidBefore = Just index}))
  witnesses <- budgetWitnesses values
  pure (Sub.assemble encoded witnesses Nothing)

propPoolUpdates :: Property
propPoolUpdates = property $ do
  groups <- forAll (Gen.list (Range.linear 2 5) (Gen.list (Range.linear 0 8) poolEvent))
  let registrations = [key | events <- groups, Register key <- events]
      globalKeys = Set.fromList registrations
      safeDeposit = (2 ^ (63 :: Int) - 1) `quot` max 1 (toInteger (length registrations))
  deposit <- forAll (Gen.element [0, 1, 23, 24, 65536, safeDeposit])
  raw <- evalEither ProtocolFixture.parameters
  let parameters = raw {Parameters.parameterPoolDeposit = fromInteger deposit}
  bodyFields <- evalEither $ traverse (uncurry poolFields) (zip [0 ..] groups)
  let (outerFields, localFields) = case bodyFields of [] -> (Fields.fields [] [], []); first : rest -> (first, rest)
  locals <- evalEither (traverse (fmap Sub.fromBody . SubBody.fromBody . SubBody.fromFields) localFields)
  encoded <- evalEither (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = outerFields, Body.bodySubTransactions = Just locals}))
  let transaction = Tx.fromBody encoded
      expectedBatch = negate (toInteger (Set.size globalKeys) * deposit)
      original = Tx.encodeCbor transaction
  classify "same operator updated across bodies" (length registrations > Set.size globalKeys)
  classify "retirement interleaved with registration" (any (any isRetirement) groups && not (null registrations))
  classify "large signed-safe deposit" (deposit > 2 ^ (32 :: Int))
  actual <- evalIO (Building.batchImbalance parameters [] transaction) >>= evalEither
  Value.quantity Asset.Ada actual === expectedBatch
  Value.toList actual === [(Asset.Ada, expectedBatch) | expectedBatch /= 0]
  top <- evalIO (Building.implicitCoin parameters transaction) >>= evalEither
  let outerEvents = case groups of [] -> []; first : _ -> first
  Building.deposits top === fromInteger (toInteger (Set.size (Set.fromList [key | Register key <- outerEvents])) * deposit)
  Building.reclaimedDeposits top === 0
  Tx.encodeCbor transaction === original
  where
    isRetirement (Retire _) = True
    isRetirement _ = False

poolEvent :: Gen PoolEvent
poolEvent = Gen.choice [Register <$> Gen.element [1, 2, 3, 4], Retire <$> Gen.element [1, 2, 3, 4]]

poolFields :: Word64 -> [PoolEvent] -> Either Error Fields.Fields
poolFields bodyIndex events = do
  stake <- Credential.keyHashFromBytes (B.replicate 28 12)
  let reward = Reward.fromCredential Network.testnet (Credential.KeyCredential stake)
  certificates <- forM (zip [0 ..] events) $ \(position, event) -> case event of
    Register key -> do
      operator <- Credential.keyHashFromBytes (B.replicate 28 key)
      vrf <- Pool.vrfKeyHashFromBytes (B.replicate 32 key)
      margin <- Unit.mkUnitInterval 0 1
      -- Alter non-identity fields: repeated registrations must not become
      -- byte-identical certificates whose collection handling masks the test.
      pure (Certificate.PoolRegistration (Pool.PoolParameters operator vrf Nothing (bodyIndex * 100 + position) position margin reward Set.empty [] Nothing))
    Retire key -> Certificate.PoolRetirement <$> Credential.keyHashFromBytes (B.replicate 28 key) <*> pure 42
  pure ((Fields.fields [] []) {Fields.fieldInvalidBefore = Just bodyIndex, Fields.fieldCertificates = if null certificates then Nothing else Just (Certificates.fromList certificates)})
