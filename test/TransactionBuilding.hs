{-# LANGUAGE ForeignFunctionInterface #-}
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

-- | Native contract corpus: pinned cardano-c transaction_builder/fee.c,
-- balancing/implicit_coin.c, tests/transaction_builder/script_data_hash.cpp
-- (datum-only digest), Apache-2.0. Inputs are assembled through public values;
-- rational and serialized-size expectations are calculated independently.
module TransactionBuilding (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as AssetName
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (InvalidExUnits, NativeError))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.Building as Internal
import qualified Cometa.Internal.ParameterSnapshot as Snapshot
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Protocol.CostModels as Models
import qualified Cometa.Protocol.ExUnitPrices as Prices
import qualified Cometa.Protocol.ExUnits as Ex
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Rational as Rational
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Building as Building
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as Id
import qualified Cometa.UnitInterval as Unit
import qualified Cometa.Value as Value
import Control.Monad (forM_, replicateM_)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import qualified Data.Set as Set
import qualified Data.Text
import Data.Word (Word64, Word8)
import qualified Fixtures.ProtocolParameters as Fixture
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Transaction building utilities"
    [ testCase "serialization sizes agree with native and retain exact encodings" checkSizes,
      testCase "execution totals and exact pricing reject overflow" checkExecution,
      testCase "outer, local intent and complete batch accounting agree" checkBalance,
      testCase "balance includes mint, withdrawals and direct account deposits" checkAccountBalance,
      testCase "pool deposits are charged once across a batch" checkPoolBatch,
      testCase "balance rejects unresolved, duplicate and overflowing inputs" checkBalanceErrors,
      testCase "fee uses actual ledger frame size and checked arithmetic" checkBaseFee,
      testCase "minimum Ada adjusts coin width and rejects multiplication overflow" checkMinimumAda,
      testCase "exact rational reference tiers and execution fees agree" checkFees,
      testCase "reference coverage includes subtransactions and rejects duplicates" checkCoverage,
      testCase "spending scripts and per-body pricing match native balancing" checkSpendingScripts,
      testCase "datum-only native corpus hash and empty absence" checkHash,
      testCase "implicit deposits and refunds are separate checked totals" checkImplicit,
      testCase "malformed native requests unwind and following calls succeed" checkMalformed
    ]

must :: (Show e) => Either e a -> IO a
must value = case value of
  Left failure -> assertFailure (show failure) >> fail "Invalid fixture"
  Right result -> pure result

transaction :: Body.Body -> IO Tx.Transaction
transaction body = Tx.fromBody <$> must (Body.fromBody body)

fixture :: IO (Parameters.Parameters, Utxo.Utxo)
fixture = do
  parameters <- must Fixture.parameters
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  ident <- must (Id.fromBytes (B.replicate 32 8))
  let address = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
  script <- must (Plutus.fromBytes Plutus.V3 (B.replicate 26000 1))
  output <- must (Output.mkOutput address (Value.lovelace 2000000) Datum.NoDatum (Just (Script.Plutus script)))
  pure (parameters, Utxo.utxo (Input.input ident 0) output)

checkBaseFee :: IO ()
checkBaseFee = do
  tx <- transaction (Body.body [] [] 0)
  Building.baseFee 17 3 tx >>= (@?= Right (17 + 3 * fromIntegral (B.length (Tx.encodeCbor tx) - 1)))
  Building.baseFee maxBound 1 tx >>= assertOverflow
  Building.baseFee 0 maxBound tx >>= assertOverflow
  Building.baseFee 0 0 tx >>= (@?= Right 0)

checkMinimumAda :: IO ()
checkMinimumAda = do
  (_, resolved) <- fixture
  let output = Utxo.output resolved
      bytes = B.length (Output.encodeCbor output)
  -- Both the starting and minimum coins require five CBOR bytes.
  Building.minimumAda 4310 output >>= (@?= Right (fromIntegral (bytes + 160) * 4310))
  Building.minimumAda 0 output >>= (@?= Right 0)
  Building.minimumAda maxBound output >>= assertOverflow

checkFees :: IO ()
checkFees = do
  (parameters, resolved) <- fixture
  stride <- must (Parameters.mkReferenceScriptCostStride 25600)
  multiplier <- must (Rational.mkNonNegativeRational 6 5)
  let params = parameters {Parameters.parameterRefScriptCostStride = Just stride, Parameters.parameterRefScriptCostMultiplier = Just multiplier}
      body = (Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldReferenceInputs = Just [Utxo.input resolved]}}
      argument = Data.fromData (Data.Integer 42)
      redeemer = Redeemer.Redeemer Redeemer.Spending 0 argument (Ex.ExUnits 3 4)
  witnesses <- Witnesses.fromWitnesses <$> must (Witnesses.mkWitnesses [] [] [] [] [redeemer])
  encoded <- must (Body.fromBody body)
  let tx = Tx.assemble encoded witnesses Nothing
  Building.referenceScriptFee params [resolved] >>= (@?= Right 60853)
  base <- Building.baseFee (Parameters.parameterMinFeeB params) (Parameters.parameterMinFeeA params) tx >>= must
  Building.minimumFee params [resolved] tx >>= (@?= Right (base + 17 + 60853))
  -- Missing tier parameters select the same Conway pricing.
  Building.referenceScriptFee (params {Parameters.parameterRefScriptCostStride = Nothing, Parameters.parameterRefScriptCostMultiplier = Nothing}) [resolved] >>= (@?= Right 60853)
  Building.minimumFee (params {Parameters.parameterExecutionCosts = Nothing}) [resolved] tx >>= assertBool "missing prices" . isLeft
  Building.referenceScriptFee (params {Parameters.parameterRefScriptCostPerByte = Nothing}) [] >>= assertBool "missing reference price" . isLeft

checkCoverage :: IO ()
checkCoverage = do
  (params, resolved) <- fixture
  let fields = (Fields.fields [] []) {Fields.fieldReferenceInputs = Just [Utxo.input resolved]}
  sub <- Sub.fromBody <$> must (SubBody.fromBody (SubBody.fromFields fields))
  tx <- transaction ((Body.body [] [] 0) {Body.bodySubTransactions = Just [sub]})
  Building.minimumFee params [] tx >>= assertBool "unresolved subtransaction reference" . isLeft
  Building.minimumFee params [resolved, resolved] tx >>= assertBool "duplicate references" . isLeft
  Building.referenceScriptFee params [resolved, resolved] >>= assertBool "duplicate reference pricing" . isLeft
  Building.minimumFee params [resolved] tx >>= assertBool "resolved subtransaction succeeds" . not . isLeft
  empty <- transaction (Body.body [] [] 0)
  Building.minimumFee params [resolved] empty >>= assertBool "extraneous reference" . isLeft

checkSpendingScripts :: IO ()
checkSpendingScripts = do
  (params, resolved) <- fixture
  let reference = Utxo.input resolved
      base = Building.baseFee (Parameters.parameterMinFeeB params) (Parameters.parameterMinFeeA params)
  expected <- Building.referenceScriptFee params [resolved] >>= must
  spending <- transaction (Body.body [reference] [] 0)
  linear <- base spending >>= must
  let original = Tx.encodeCbor spending
  Building.minimumFee params [] spending >>= assertBool "spending inputs must resolve" . isLeft
  Building.minimumFee params [resolved] spending >>= (@?= Right (linear + expected))
  Tx.encodeCbor spending @?= original
  both <- transaction ((Body.body [reference] [] 0) {Body.bodyFields = (Fields.fields [reference] []) {Fields.fieldReferenceInputs = Just [reference]}})
  bothLinear <- base both >>= must
  Building.minimumFee params [resolved] both >>= (@?= Right (bothLinear + expected))
  -- The native balancing workflow concatenates each body's priced input set.
  sub <- Sub.fromBody <$> must (SubBody.fromBody (SubBody.body [reference] []))
  batch <- transaction ((Body.body [reference] [] 0) {Body.bodySubTransactions = Just [sub]})
  batchLinear <- base batch >>= must
  -- Fixture byte price 7/3, stride 2^32-1: 52000 script bytes priced once.
  Building.minimumFee params [resolved] batch >>= (@?= Right (batchLinear + 121333))

checkHash :: IO ()
checkHash = do
  Building.scriptDataHash Models.empty (Witnesses.fromWitnesses Witnesses.empty) >>= (@?= Right Nothing)
  let datum = Data.fromData (Data.Integer 1234567890123456789012345678901234567890)
  witnesses <- Witnesses.fromWitnesses <$> must (Witnesses.mkWitnesses [] [] [] [datum] [])
  result <- Building.scriptDataHash Models.empty witnesses >>= must
  expected <- must (Datum.hashFromBytes (B.pack [191, 20, 132, 113, 227, 65, 210, 160, 214, 174, 156, 206, 200, 247, 199, 91, 95, 21, 83, 72, 184, 175, 57, 201, 251, 134, 185, 85, 117, 172, 156, 60]))
  result @?= Just expected
  -- Exact imported datum encoding contributes to the commitment.
  different <- must (Witnesses.decodeCbor (B.pack [0xa1, 0x04, 0x81, 0x18, 0x01]))
  minimal <- must (Witnesses.decodeCbor (B.pack [0xa1, 0x04, 0x81, 0x01]))
  a <- Building.scriptDataHash Models.empty different >>= must
  b <- Building.scriptDataHash Models.empty minimal >>= must
  assertBool "nonminimal datum bytes remain committed" (a /= b)

checkImplicit :: IO ()
checkImplicit = do
  (params, _) <- fixture
  stakeHash <- must (Credential.keyHashFromBytes (B.replicate 28 1))
  let stake = Credential.KeyCredential stakeHash
      certificates = Certificates.fromList [Certificate.StakeRegistration stake, Certificate.StakeDeregistration stake]
      body = (Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldCertificates = Just certificates}}
  tx <- transaction body
  Building.implicitCoin params tx >>= (@?= Right (Building.ImplicitCoin 0 (Parameters.parameterKeyDeposit params) (Parameters.parameterKeyDeposit params)))
  sub <- Sub.fromBody <$> must (SubBody.fromBody (SubBody.fromFields (Body.bodyFields body)))
  Building.subTransactionImplicitCoin params sub >>= (@?= Right (Building.ImplicitCoin 0 (Parameters.parameterKeyDeposit params) (Parameters.parameterKeyDeposit params)))
  enclosing <- transaction ((Body.body [] [] 0) {Body.bodySubTransactions = Just [sub]})
  Building.implicitCoin params enclosing >>= (@?= Right (Building.ImplicitCoin 0 0 0))
  otherHash <- must (Credential.keyHashFromBytes (B.replicate 28 2))
  let account = Reward.fromCredential Network.testnet stake
      other = Reward.fromCredential Network.testnet (Credential.KeyCredential otherHash)
  amounts <- must (Fields.mkEntries [(account, 17), (other, 23)])
  withdrawing <- transaction ((Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldWithdrawals = Just amounts}})
  Building.implicitCoin params withdrawing >>= (@?= Right (Building.ImplicitCoin 40 0 0))
  excessive <- must (Fields.mkEntries [(account, maxBound), (other, 1)])
  withdrawingOverflow <- transaction ((Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldWithdrawals = Just excessive}})
  Building.implicitCoin params withdrawingOverflow >>= assertOverflow
  let registrations = Certificates.fromList [Certificate.StakeRegistration stake, Certificate.StakeRegistration stake]
  overflow <- transaction ((Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldCertificates = Just registrations}})
  Building.implicitCoin (params {Parameters.parameterKeyDeposit = maxBound}) overflow >>= assertOverflow

checkMalformed :: IO ()
checkMalformed = do
  forM_ [0 .. 8] $ \operation -> replicateM_ 20 $ do
    Internal.runUnchecked operation (B.pack [0x82, 0xa0, 0xa0, 0xff]) >>= assertBool "malformed request" . isLeft
  Internal.runUnchecked 99 (B.pack [0x82, 0xa0, 0xa0]) >>= assertBool "unknown operation" . isLeft
  tx <- transaction (Body.body [] [] 0)
  replicateM_ 20 (Building.baseFee 1 1 tx >>= assertBool "fresh native scope after failures" . not . isLeft)
  (parameters, _) <- fixture
  local <- Sub.fromBody <$> must (SubBody.fromBody (SubBody.body [] []))
  forM_ [(6, Tx.encodeCbor tx), (7, Sub.encodeCbor local), (8, Tx.encodeCbor tx)] $ \(operation, encoded) ->
    replicateM_ 20 $
      Internal.runUnchecked operation (B.singleton 0x83 <> encoded <> Snapshot.encodeSnapshot parameters <> B.pack [0x81, 0x80])
        >>= assertBool "partial imbalance request accepted" . isLeft
  Building.batchImbalance parameters [] tx >>= (@?= Right mempty)

assertOverflow :: Either Error a -> IO ()
assertOverflow result = case result of
  Left (NativeError _ code diagnostic) -> do
    code @?= Code.IntegerOverflow
    assertBool "copied native diagnostic is available" (not (Data.Text.null diagnostic))
  Left failure -> assertFailure (show failure)
  Right _ -> assertFailure "Expected native integer overflow"

checkBalance :: IO ()
checkBalance = do
  (parameters, input) <- fixture
  output <- must (Output.mkOutput (Output.address (Utxo.output input)) (Value.lovelace 1800000) Datum.NoDatum Nothing)
  balanced <- transaction (Body.body [Utxo.input input] [output] 200000)
  Building.imbalance parameters [input] balanced >>= (@?= Right mempty)
  Building.isBalanced parameters [input] balanced >>= (@?= Right True)

  localOutput <- must (Output.mkOutput (Output.address output) (Value.lovelace 1000000) Datum.NoDatum Nothing)
  localBody <- must (SubBody.fromBody (SubBody.body [Utxo.input input] [localOutput]))
  let intent = Sub.fromBody localBody
  Building.subTransactionImbalance parameters [input] intent >>= (@?= Right (Value.lovelace 1000000))

  change <- must (Output.mkOutput (Output.address output) (Value.lovelace 800000) Datum.NoDatum Nothing)
  batch <- transaction (Body.body [] [change] 200000) {Body.bodySubTransactions = Just [intent]}
  let before = Tx.encodeCbor batch
  Building.imbalance parameters [input] batch >>= (@?= Right (Value.lovelace (-1000000)))
  Building.batchImbalance parameters [input] batch >>= (@?= Right mempty)
  Building.isBalanced parameters [input] batch >>= (@?= Right True)
  Tx.encodeCbor batch @?= before

checkAccountBalance :: IO ()
checkAccountBalance = do
  (parameters, funding) <- fixture
  policy <- must (Policy.fromBytes (B.replicate 28 1))
  key <- must (Credential.keyHashFromBytes (B.replicate 28 2))
  let token = Asset.Native policy AssetName.empty
      account = Reward.fromCredential Network.testnet (Credential.KeyCredential key)
      address = Output.address (Utxo.output funding)
  source <- must (Output.mkOutput address (Value.lovelace 2000000 <> Value.singleton token 5) Datum.NoDatum Nothing)
  output <- must (Output.mkOutput address (Value.lovelace 2000000 <> Value.singleton token 3) Datum.NoDatum Nothing)
  mint <- must (Fields.mkMint (Value.singleton token (-2)))
  withdrawals <- must (Fields.mkEntries [(account, 17)])
  deposits <- must (Fields.mkEntries [(account, 7)])
  let input = Utxo.utxo (Utxo.input funding) source
      fields =
        (Fields.fields [Utxo.input input] [output])
          { Fields.fieldMint = Just mint,
            Fields.fieldWithdrawals = Just withdrawals,
            Fields.fieldDirectDeposits = Just deposits,
            Fields.fieldDonation = Just 3
          }
  tx <- transaction (Body.body [] [] 7) {Body.bodyFields = fields}
  Building.batchImbalance parameters [input] tx >>= (@?= Right mempty)

checkPoolBatch :: IO ()
checkPoolBatch = do
  (raw, input) <- fixture
  operator <- must (Credential.keyHashFromBytes (B.replicate 28 3))
  stake <- must (Credential.keyHashFromBytes (B.replicate 28 4))
  vrf <- must (Pool.vrfKeyHashFromBytes (B.replicate 32 5))
  margin <- must (Unit.mkUnitInterval 0 1)
  let pool = Pool.PoolParameters operator vrf Nothing 0 0 margin (Reward.fromCredential Network.testnet (Credential.KeyCredential stake)) Set.empty [] Nothing
      certificates = Just (Certificates.fromList [Certificate.PoolRegistration pool])
      parameters = raw {Parameters.parameterPoolDeposit = 100}
  output <- must (Output.mkOutput (Output.address (Utxo.output input)) (Value.lovelace 1999900) Datum.NoDatum Nothing)
  localBody <- must (SubBody.fromBody (SubBody.fromFields (Fields.fields [] []) {Fields.fieldCertificates = certificates}))
  let intent = Sub.fromBody localBody
      fields = (Fields.fields [Utxo.input input] [output]) {Fields.fieldCertificates = certificates}
  batch <- transaction (Body.body [] [] 0) {Body.bodyFields = fields, Body.bodySubTransactions = Just [intent]}
  Building.imbalance parameters [input] batch >>= (@?= Right mempty)
  Building.subTransactionImbalance parameters [input] intent >>= (@?= Right (Value.lovelace (-100)))
  Building.batchImbalance parameters [input] batch >>= (@?= Right mempty)

checkBalanceErrors :: IO ()
checkBalanceErrors = do
  (parameters, input) <- fixture
  tx <- transaction (Body.body [Utxo.input input] [] 0)
  Building.imbalance parameters [] tx >>= assertBool "missing resolution accepted" . isLeft
  Building.imbalance parameters [input, input] tx >>= assertBool "duplicate resolution accepted" . isLeft
  large <- must (Output.mkOutput (Output.address (Utxo.output input)) (Value.lovelace 9223372036854775807) Datum.NoDatum Nothing)
  otherId <- must (Id.fromBytes (B.replicate 32 9))
  let first = Utxo.utxo (Utxo.input input) large
      second = Utxo.utxo (Input.input otherId 0) large
  overflow <- transaction (Body.body [Utxo.input first, Utxo.input second] [] 0)
  Building.batchImbalance parameters [first, second] overflow >>= assertBool "overflow accepted" . isLeft

-- Independent calculations from the pinned native fee.c, exercised through
-- standalone native owners in test/cbits/runtime_oracle.c. Apache-2.0.
checkSizes :: IO ()
checkSizes = do
  forM_ [(0, 1), (23, 1), (24, 2), (255, 2), (256, 3), (65535, 3), (65536, 5), (4294967295, 5), (4294967296, 9), (maxBound, 9)] $ \(coin, expected) -> do
    Building.coinSize coin @?= expected
    alloca $ \size -> do
      cCoinSize coin size >>= (@?= 0)
      peek size >>= (@?= fromIntegral expected)
  (_, resolved) <- fixture
  let output = Utxo.output resolved
  nativeSize 1 (Output.encodeCbor output) >>= (@?= fromIntegral (Building.outputSize output))
  minimal <- must (Native.decodeCbor (B.pack [0x82, 5, 1]))
  retained <- must (Native.decodeCbor (B.pack [0x82, 5, 0x1b, 0, 0, 0, 0, 0, 0, 0, 1]))
  Building.scriptSize (Script.Native minimal) @?= 3
  Building.scriptSize (Script.Native retained) @?= 11
  plutus <- must (Plutus.decodeCbor Plutus.V4 (B.pack [0x58, 2, 1, 2]))
  Building.scriptSize (Script.Plutus plutus) @?= 2
  forM_ [Script.Native minimal, Script.Native retained, Script.Plutus plutus] $ \script ->
    nativeSize 2 (Script.encodeCbor script) >>= (@?= fromIntegral (Building.scriptSize script))
  tx <- transaction (Body.body [] [output] 0)
  nativeSize 0 (Tx.encodeCbor tx) >>= (@?= fromIntegral (Building.transactionSize tx))
  -- The retained three-element frame has no validity flag to count.
  legacy <- must (Tx.decodeCbor (B.pack [0x83, 0xa3, 0, 0x80, 1, 0x80, 2, 0, 0xa0, 0xf6]))
  nativeSize 0 (Tx.encodeCbor legacy) >>= (@?= fromIntegral (Building.transactionSize legacy))

checkExecution :: IO ()
checkExecution = do
  Building.totalExecutionUnits [] @?= Right (Ex.ExUnits 0 0)
  let argument = Data.fromData (Data.Integer 0)
      redeemer memory steps = Redeemer.Redeemer Redeemer.Spending 0 argument (Ex.ExUnits memory steps)
  Building.totalExecutionUnits [redeemer 1 2, redeemer 3 4] @?= Right (Ex.ExUnits 4 6)
  Building.totalExecutionUnits [redeemer maxBound 0] @?= Right (Ex.ExUnits maxBound 0)
  Building.totalExecutionUnits [redeemer maxBound 0, redeemer 1 0] @?= Left (InvalidExUnits (2 ^ (64 :: Int)) 0)
  Building.totalExecutionUnits [redeemer 0 maxBound, redeemer 0 1] @?= Left (InvalidExUnits 0 (2 ^ (64 :: Int)))
  memoryPrice <- must (Rational.mkNonNegativeRational 7 3)
  stepPrice <- must (Rational.mkNonNegativeRational 11 7)
  let prices = Prices.ExUnitPrices memoryPrice stepPrice
  encoded <- must (Body.fromBody (Body.body [] [] 0))
  forM_ [(0, 0), (1, 0), (0, 1), (1, 1), (3, 7), (100000, 100000)] $ \(memory, steps) -> do
    let budget = Ex.ExUnits memory steps
    witnesses <- Witnesses.fromWitnesses <$> must (Witnesses.mkWitnesses [] [] [] [] [redeemer memory steps])
    let tx = Tx.assemble encoded witnesses Nothing
    expected <- nativeSize 3 (Tx.encodeCbor tx)
    Building.executionFee prices budget @?= Right expected
  localBody <- must (SubBody.fromBody (SubBody.body [] []))
  localWitnesses <- Witnesses.fromWitnesses <$> must (Witnesses.mkWitnesses [] [] [] [] [redeemer 2 6])
  outerWitnesses <- Witnesses.fromWitnesses <$> must (Witnesses.mkWitnesses [] [] [] [] [redeemer 1 1])
  let local = Sub.setWitnesses localWitnesses (Sub.fromBody localBody)
  enclosingBody <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodySubTransactions = Just [local]}))
  let enclosing = Tx.assemble enclosingBody outerWitnesses Nothing
  total <- must (Building.totalExecutionUnits [redeemer 1 1, redeemer 2 6])
  nativeSize 3 (Tx.encodeCbor enclosing) >>= (@?= 18)
  Building.executionFee prices total @?= Right 18
  Building.executionFee prices (Ex.ExUnits 3 7) @?= Right 18
  half <- must (Rational.mkNonNegativeRational 1 2)
  Building.executionFee (Prices.ExUnitPrices half half) (Ex.ExUnits 1 1) @?= Right 1
  tiny <- must (Rational.mkNonNegativeRational 1 (toInteger (maxBound :: Word64)))
  almostOne <- must (Rational.mkNonNegativeRational (toInteger (maxBound :: Word64) - 1) (toInteger (maxBound :: Word64)))
  Building.executionFee (Prices.ExUnitPrices tiny almostOne) (Ex.ExUnits 1 1) @?= Right 1
  largest <- must (Rational.mkNonNegativeRational (toInteger (maxBound :: Word64)) 1)
  zero <- must (Rational.mkNonNegativeRational 0 1)
  let expensive = Prices.ExUnitPrices largest zero
  Building.executionFee expensive (Ex.ExUnits 0 0) @?= Right 0
  Building.executionFee expensive (Ex.ExUnits 1 0) @?= Right maxBound
  assertBool "fee overflow" (isLeft (Building.executionFee expensive (Ex.ExUnits 2 0)))

nativeSize :: Word8 -> B.ByteString -> IO Word64
nativeSize kind bytes = B.useAsCStringLen bytes $ \(input, size) -> alloca $ \output -> do
  cBuildingSize kind (castPtr input) (fromIntegral size) output >>= (@?= 0)
  peek output

foreign import ccall unsafe "cometa_test_building_sizes_oracle"
  cBuildingSize :: Word8 -> Ptr Word8 -> CSize -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "cardano_get_serialized_coin_size"
  cCoinSize :: Word64 -> Ptr CSize -> IO CInt
