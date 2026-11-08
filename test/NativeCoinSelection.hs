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

-- | Cases adapted from cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/transaction_builder/coin_selection/random_improve_coin_selector.cpp
-- (Apache-2.0): deterministic replay, insufficient funds and change shape.
-- All inputs are assembled through typed public values; accounting is checked
-- independently in Haskell and minimum Ada through the actual native oracle.
module NativeCoinSelection (tests) where

import qualified Codec.CBOR.Encoding as E
import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as Name
import qualified Cometa.CoinSelection as Selection
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (InvalidSelectionRequest, NativeError))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Internal.CoinSelection as Wire
import qualified Cometa.Internal.CoinSelection.Native as Native
import qualified Cometa.Internal.FFI.CoinSelection as FFI
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.Internal.TransactionValue as NativeValue
import qualified Cometa.NetworkId as Network
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, replicateM, replicateM_, (>=>))
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import qualified Fixtures.ProtocolParameters as Fixture
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek)
import Hedgehog (Gen, Property, PropertyT, assert, classify, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Native coin selection"
    [ testCase "largest-first orders quantities and ignores output hints" checkLargest,
      testCase "seeded policies replay exact complete results" checkReplay,
      testCase "native round-robin change follows output shape" checkShape,
      testCase "mandatory disjoint/overlap and exact match preserve accounting" checkMandatory,
      testCase "zero target still spends an input" checkZero,
      testCase "multiasset change splits at the native value bound" checkAssets,
      testCase "insufficient target and change Ada fail and recover" checkFailure,
      testCase "aggregate native arithmetic bounds fail before selection" checkBounds,
      testCase "signed implicit surplus preserves coin and native-asset change" checkSigned,
      testCase "repeated and concurrent invocations survive GC and callback dispatch" checkLifecycle,
      testProperty "generated native strategies preserve full accounting" propAccounting,
      testProperty "upstream multiasset exact and surplus selection laws" propMultiassetSelection,
      testProperty "upstream generated insufficient coin and token supplies fail" propInsufficientSupply,
      testProperty "upstream generated splitting preserves quantities and size bounds" propSplitBundles
    ]

must :: (Show e) => Either e a -> IO a
must = either (\failure -> assertFailure (show failure) >> fail "Invalid fixture") pure

requestFor :: [Value.Value] -> Value.Value -> IO Selection.SelectionRequest
requestFor values target = do
  params <- must Fixture.parameters
  key <- must (Credential.keyHashFromBytes (B.replicate 28 7))
  txId <- must (Id.fromBytes (B.replicate 32 8))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
  candidates <-
    sequence
      [ do
          output <- must (Output.mkOutput destination value Datum.NoDatum Nothing)
          pure (Utxo.utxo (Input.input txId ix) output)
      | (ix, value) <- zip ([0 ..] :: [Word64]) values
      ]
  must (Selection.mkSelectionRequest (Selection.SelectionOptions [] candidates target Nothing destination (params {Parameters.parameterAdaPerUtxoByte = Just 4310, Parameters.parameterMaxValueSize = Just 5000})))

options :: Selection.SelectionRequest -> Selection.SelectionOptions
options request = Selection.SelectionOptions (Selection.preselected request) (Selection.available request) (Selection.target request) (Selection.outputHints request) (Selection.changeAddress request) (Selection.parameters request)

algorithms :: [Selection.Selector]
algorithms = [Selection.largestFirst, Selection.randomImprove, Selection.randomImproveWithSeed 7, Selection.randomImproveWithOptions 7 Selection.Minimal]

checked :: Selection.Selector -> Selection.SelectionRequest -> IO Selection.Selection
checked selector request = do
  result <- Selection.select selector request >>= must
  Selection.validateSelection request result @?= Right ()
  foldMap (Output.value . Utxo.output) (Selection.selected result) @?= Selection.target request <> foldMap Output.value (Selection.change result)
  forM_ (Selection.change result) $ \output -> Runtime.withBytes (Output.encodeCbor output) $ \bytes size -> alloca $ \minimumSlot -> do
    code <- FFI.cMinimumAda bytes size 4310 minimumSlot
    Runtime.checkStatus "test.nativeSelection.minimumAda" code >>= must
    amount <- peek minimumSlot
    assertBool "change below native minimum Ada" (Value.quantity Asset.Ada (Output.value output) >= toInteger amount)
  pure result

checkLargest :: IO ()
checkLargest = do
  request <- requestFor (map Value.lovelace [3000000, 9000000, 2000000]) (Value.lovelace 6000000)
  result <- checked Selection.largestFirst request
  map (Value.quantity Asset.Ada . Output.value . Utxo.output) (Selection.selected result) @?= [9000000]
  hint <- must (Output.mkOutput (Selection.changeAddress request) (Value.lovelace 99999999) Datum.NoDatum Nothing)
  hinted <- must (Selection.mkSelectionRequest ((options request) {Selection.selectionOutputHints = Just [hint, hint]}))
  checked Selection.largestFirst hinted >>= (@?= result)

checkReplay :: IO ()
checkReplay = do
  request <- requestFor (map (Value.lovelace . (* 1000000)) [1 .. 20]) (Value.lovelace 15000000)
  forM_ [Selection.Minimal, Selection.Optimal] $ \strategy -> do
    let selector = Selection.randomImproveWithOptions 7 strategy
    first <- checked selector request
    replicateM_ 8 (checked selector request >>= (@?= first))
  checked (Selection.randomImproveWithSeed 7) request >>= \result -> checked (Selection.randomImproveWithOptions 7 Selection.Optimal) request >>= (@?= result)

checkShape :: IO ()
checkShape = do
  request <- requestFor (replicate 20 (Value.lovelace 3000000)) (Value.lovelace 10000000)
  hint <- must (Output.mkOutput (Selection.changeAddress request) (Value.lovelace 5000000) Datum.NoDatum Nothing)
  hinted <- must (Selection.mkSelectionRequest ((options request) {Selection.selectionOutputHints = Just [hint, hint]}))
  result <- checked (Selection.randomImproveWithSeed 42) hinted
  length (Selection.change result) @?= 2

checkMandatory :: IO ()
checkMandatory = do
  request <- requestFor (map Value.lovelace [3000000, 7000000, 2000000]) (Value.lovelace 10000000)
  case Selection.available request of
    mandatory : rest -> forM_ algorithms $ \selector -> forM_ [rest, mandatory : rest] $ \available -> do
      required <- must (Selection.mkSelectionRequest ((options request) {Selection.selectionPreselected = [mandatory], Selection.selectionAvailable = available}))
      result <- checked selector required
      assertBool "mandatory input dropped" (mandatory `elem` Selection.selected result)
    [] -> assertFailure "Empty fixture"
  exact <- requestFor [Value.lovelace 10000000] (Value.lovelace 10000000)
  forM_ algorithms $ \selector -> checked selector exact >>= \result -> Selection.change result @?= []

checkZero :: IO ()
checkZero = do
  request <- requestFor (map Value.lovelace [3000000, 9000000]) mempty
  forM_ algorithms $ \selector -> checked selector request >>= \result -> assertBool "zero target produced empty selection" (not (null (Selection.selected result)))

checkAssets :: IO ()
checkAssets = do
  policy <- must (Policy.fromBytes (B.replicate 28 9))
  names <- mapM (must . Name.fromBytes . B.singleton) [1 .. 12]
  let tokens = Value.fromList [(Asset.Native policy name, 100) | name <- names]
  request <- requestFor [Value.lovelace 100000000 <> tokens] (Value.lovelace 1000000)
  small <- must (Selection.mkSelectionRequest ((options request) {Selection.selectionParameters = (Selection.parameters request) {Parameters.parameterMaxValueSize = Just 65}}))
  forM_ algorithms $ \selector -> do
    result <- checked selector small
    assertBool "oversized bundle was not split" (length (Selection.change result) > 1)
    -- Native size assessment substitutes the maximum supply (45 billion Ada)
    -- for coin, so its final width cannot make a split map exceed the limit.
    forM_ (Selection.change result) $ \output -> do
      let boundedValue = Cbor.encode (E.encodeListLen 2 <> E.encodeInteger 45000000000000000 <> NativeValue.encodeAssets (Output.value output))
      assertBool "split value exceeds native maximum size" (B.length boundedValue <= 65)
    assertBool "native assets lost in split" (foldMap Output.value (Selection.change result) == Value.lovelace 99000000 <> tokens)

checkFailure :: IO ()
checkFailure = do
  insufficient <- requestFor [Value.lovelace 1000000] (Value.lovelace 5000000)
  dust <- requestFor [Value.lovelace 5000001] (Value.lovelace 5000000)
  empty <- requestFor [] mempty
  recovery <- requestFor [Value.lovelace 10000000] (Value.lovelace 10000000)
  forM_ algorithms $ \selector -> do
    forM_ [insufficient, dust, empty] (Selection.select selector >=> assertBool "native insufficient funds accepted" . isLeft)
    _ <- checked selector recovery
    pure ()

checkBounds :: IO ()
checkBounds = do
  overflow <- requestFor (replicate 2 (Value.lovelace (2 ^ (62 :: Int)))) (Value.lovelace 1)
  request <- requestFor [Value.lovelace 10000000] (Value.lovelace 5000000)
  excessive <- must (Selection.mkSelectionRequest ((options request) {Selection.selectionParameters = (Selection.parameters request) {Parameters.parameterAdaPerUtxoByte = Just maxBound}}))
  hint <- must (Output.mkOutput (Selection.changeAddress request) (Value.lovelace 1) Datum.NoDatum Nothing)
  -- Each output's bound alone fits, but two shape-hinted maps exceed the signed
  -- sum consumed by largest-first. This must reject before native arithmetic.
  splitCost <- must (Selection.mkSelectionRequest ((options request) {Selection.selectionOutputHints = Just [hint, hint], Selection.selectionParameters = (Selection.parameters request) {Parameters.parameterAdaPerUtxoByte = Just (fromIntegral (maxBound :: Word64) `div` 600)}}))
  forM_ algorithms $ \selector -> forM_ [overflow, excessive, splitCost] $ \invalid -> do
    answer <- Selection.select selector invalid
    case answer of
      Left (InvalidSelectionRequest _) -> pure ()
      other -> assertFailure ("Expected preflight request failure, received " ++ show other)

checkSigned :: IO ()
checkSigned = do
  policy <- must (Policy.fromBytes (B.replicate 28 9))
  let token = Asset.Native policy Name.empty
  forM_ [Value.lovelace (-2000000), Value.lovelace 1000000 <> Value.singleton token (-100)] $ \target -> do
    request <- requestFor [Value.lovelace 3000000] target
    Wire.decodeRequest (Wire.encodeRequest request) @?= Right request
    forM_ algorithms $ \selector -> do
      result <- checked selector request
      -- Actual native callback snapshots must preserve signed target coin and
      -- assets, rather than encoding negative coin as an unsigned ledger value.
      Native.invoke selector request >>= must >>= (@?= result)
  boundary <- requestFor [Value.lovelace 3000000] (Value.lovelace (toInteger (minBound :: Int64)))
  Wire.decodeRequest (Wire.encodeRequest boundary) @?= Right boundary
  forM_ algorithms $ \selector -> do
    answer <- Selection.select selector boundary
    case answer of
      Left (InvalidSelectionRequest _) -> pure ()
      other -> assertFailure ("Expected negative-excess overflow guard: " ++ show other)

checkLifecycle :: IO ()
checkLifecycle = do
  request <- requestFor (replicate 10 (Value.lovelace 3000000)) (Value.lovelace 5000000)
  baseline <- Runtime.liveContexts
  forM_ algorithms $ \selector -> do
    replicateM_ 16 (performGC >> checked selector request)
    result <- checked selector request
    Native.invoke selector request >>= must >>= \roundtrip -> Selection.validateSelection request roundtrip @?= Right ()
    assertBool "native result empty" (not (null (Selection.selected result)))
    slots <- replicateM 4 newEmptyMVar
    forM_ slots $ \slot -> do
      _ <- forkFinally (checked selector request) (putMVar slot)
      pure ()
    forM_ slots (takeMVar >=> either (assertFailure . show) (const (pure ())))
  Runtime.liveContexts >>= (@?= baseline)

propAccounting :: Property
propAccounting = property $ do
  amounts <- forAll (Gen.list (Range.linear 1 20) (Gen.integral (Range.linear 2000000 20000000)))
  seed <- forAll (Gen.word64 Range.constantBounded)
  request <- evalIO (requestFor (map Value.lovelace amounts) (Value.lovelace 1000000))
  forM_ [Selection.largestFirst, Selection.randomImproveWithSeed seed, Selection.randomImproveWithOptions seed Selection.Minimal] $ \selector -> do
    result <- evalIO (Selection.select selector request) >>= evalEither
    Selection.validateSelection request result === Right ()

-- The following properties adapt BalanceSpec's exact/surplus/insufficient supply
-- and bundle-splitting laws, using small positive bundle generators with
-- integrated shrinking. See Fixtures/COIN_SELECTION.md for the pinned source,
-- upstream notices, and differences from its unbounded mock constraints.
-- Expected accounting uses Integer maps, never Value's arithmetic or a C oracle.
type Quantities = Map.Map Asset.AssetId Integer

quantitySum :: [[(Asset.AssetId, Integer)]] -> Quantities
quantitySum = Map.filter (/= 0) . Map.fromListWith (+) . concat

selectionLaws :: Selection.SelectionRequest -> Selection.Selection -> PropertyT IO ()
selectionLaws request result = do
  let selected = Selection.selected result
      references = map Utxo.input selected
      eligible = Selection.preselected request ++ Selection.available request
      selectedAmounts = quantitySum (map (Value.toList . Output.value . Utxo.output) selected)
      spentAndChange = quantitySum (Value.toList (Selection.target request) : map (Value.toList . Output.value) (Selection.change result))
      remainingReferences = Set.fromList (map Utxo.input (Selection.remaining result))
      selectedReferences = Set.fromList references
  assert (all (`elem` eligible) selected)
  length references === Set.size selectedReferences
  assert (all (`elem` selected) (Selection.preselected request))
  remainingReferences === Set.difference (Set.fromList (map Utxo.input (Selection.available request))) selectedReferences
  length (Selection.remaining result) === Set.size remainingReferences
  selectedAmounts === spentAndChange
  forM_ (Selection.change result) $ \output -> do
    Output.address output === Selection.changeAddress request
    assert (all ((>= 0) . snd) (Value.toList (Output.value output)))
    -- All generated outputs have minimum Ada in the 5-byte CBOR coin range.
    -- Calculate its Babbage UTxO cost with a fixed-width placeholder, so no
    -- native minimum-Ada call or native arithmetic supplies the expectation.
    placeholder <- evalEither (Output.mkOutput (Output.address output) (Value.fromList ((Asset.Ada, 1000000) : filter ((/= Asset.Ada) . fst) (Value.toList (Output.value output)))) Datum.NoDatum Nothing)
    let minimumAda = (160 + toInteger (B.length (Output.encodeCbor placeholder))) * 4310
    assert (minimumAda >= 65536 && minimumAda <= 4294967295)
    assert (Map.findWithDefault 0 Asset.Ada (quantitySum [Value.toList (Output.value output)]) >= minimumAda)

fixtureAssets :: IO [Asset.AssetId]
fixtureAssets = do
  policies <- mapM (must . Policy.fromBytes . B.replicate 28) [9, 10]
  names <- mapM (must . Name.fromBytes . B.singleton) [1 .. 8]
  pure [Asset.Native policy name | name <- names, policy <- policies]

genBundles :: [Asset.AssetId] -> Gen [[(Asset.AssetId, Integer)]]
genBundles assets = do
  count <- Gen.int (Range.linear 1 8)
  assetCount <- Gen.int (Range.linear 1 6)
  Gen.list (Range.singleton count) $ do
    coin <- Gen.integral (Range.linear 30000000 100000000)
    amounts <- Gen.list (Range.singleton assetCount) (Gen.integral (Range.linear 1 10000))
    pure ((Asset.Ada, coin) : zip assets amounts)

seededAlgorithms :: Word64 -> [Selection.Selector]
seededAlgorithms seed = [Selection.largestFirst, Selection.randomImproveWithSeed seed, Selection.randomImproveWithOptions seed Selection.Minimal]

propMultiassetSelection :: Property
propMultiassetSelection = property $ do
  assets <- evalIO fixtureAssets
  bundles <- forAll (genBundles assets)
  seed <- forAll (Gen.word64 Range.constantBounded)
  exact <- forAll Gen.bool
  overlap <- forAll Gen.bool
  mandatory <- forAll Gen.bool
  classify "exact supply" exact
  classify "surplus supply" (not exact)
  classify "overlapping mandatory input" (mandatory && overlap)
  classify "multiple policies" (any ((> 2) . length) bundles)
  let total = quantitySum bundles
      requested = if exact then total else Map.map (`div` 2) total
  base <- evalIO (requestFor (map Value.fromList bundles) (Value.fromList (Map.toList requested)))
  request <- case Selection.available base of
    first : rest | mandatory -> evalEither (Selection.mkSelectionRequest ((options base) {Selection.selectionPreselected = [first], Selection.selectionAvailable = if overlap then first : rest else rest}))
    _ -> pure base
  forM_ (seededAlgorithms seed) $ \selector -> do
    result <- evalIO (Selection.select selector request) >>= evalEither
    selectionLaws request result
    -- Check marshaled snapshots against the generated quantities as well as
    -- conservation: altered input quantities must not satisfy the oracle.
    forM_ (Selection.selected result) $ \selected ->
      assert (Value.toList (Output.value (Utxo.output selected)) `elem` map (Map.toAscList . quantitySum . (: [])) bundles)
    if exact then Selection.change result === [] else assert (not (null (Selection.change result)))

propInsufficientSupply :: Property
propInsufficientSupply = property $ do
  assets <- evalIO fixtureAssets
  bundles <- forAll (genBundles assets)
  seed <- forAll (Gen.word64 Range.constantBounded)
  missingCoin <- forAll Gen.bool
  deficit <- forAll (Gen.integral (Range.linear 1 10000))
  classify "insufficient Ada" missingCoin
  classify "insufficient native asset" (not missingCoin)
  let total = quantitySum bundles
  missingAsset <- if missingCoin then pure Asset.Ada else forAll (Gen.element (Map.keys (Map.delete Asset.Ada total)))
  let requested = Map.insertWith (+) missingAsset deficit total
  request <- evalIO (requestFor (map Value.fromList bundles) (Value.fromList (Map.toList requested)))
  forM_ (seededAlgorithms seed) $ \selector -> do
    result <- evalIO (Selection.select selector request)
    case result of
      Left (NativeError _ code _) -> Code.toNumber code === 1100
      _ -> assert False

propSplitBundles :: Property
propSplitBundles = property $ do
  assets <- evalIO fixtureAssets
  count <- forAll (Gen.int (Range.linear 4 16))
  limit <- forAll (Gen.int (Range.linear 65 80))
  amount <- forAll (Gen.element [1, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296, toInteger (maxBound :: Int64)])
  seed <- forAll (Gen.word64 Range.constantBounded)
  classify "signed int64 quantity endpoint" (amount == toInteger (maxBound :: Int64))
  classify "quantity above word32" (amount > 4294967295)
  let raw = (Asset.Ada, 500000000) : [(asset, amount) | asset <- take count assets]
  base <- evalIO (requestFor [Value.fromList raw] (Value.lovelace 1000000))
  request <- evalEither (Selection.mkSelectionRequest ((options base) {Selection.selectionParameters = (Selection.parameters base) {Parameters.parameterMaxValueSize = Just (fromIntegral limit)}}))
  forM_ (seededAlgorithms seed) $ \selector -> do
    result <- evalIO (Selection.select selector request) >>= evalEither
    selectionLaws request result
    assert (length (Selection.change result) > 1)
    forM_ (Selection.change result) $ \output -> do
      let quantities = Value.toList (Output.value output)
      assert (all (\(_, quantity) -> quantity <= toInteger (maxBound :: Int64)) quantities)
      -- The native bundle assessment reserves the total Ada supply width.
      -- Public CBOR encoding independently measures the resulting ledger value.
      bytes <- evalEither (Value.encodeCbor (Value.fromList ((Asset.Ada, 45000000000000000) : filter ((/= Asset.Ada) . fst) quantities)))
      assert (B.length bytes <= limit)
