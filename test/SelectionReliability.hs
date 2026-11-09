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

-- | Original selection properties inspired by cardano-coin-selection
-- 57efda2eda720b9e793a6f907319cc84aa02058c BalanceSpec (Apache-2.0).
-- Sparse incidence and signed funding extend the existing positive-bundle laws.
-- Expected balances use Integer arithmetic, never selection validation or a
-- second native call. Choice/order of random selections is deliberately free.
module SelectionReliability (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as Name
import qualified Cometa.CoinSelection as Selection
import qualified Cometa.Credential as Credential
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.NetworkId as Network
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import qualified Cometa.Value as Value
import Control.Monad (forM_, zipWithM)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import qualified Fixtures.ProtocolParameters as Fixture
import Hedgehog (Property, PropertyT, assert, classify, evalEither, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Selection reliability"
    [ testProperty "sparse signed requirements conserve assets and exact heterogeneous snapshots" propSignedSparse,
      testProperty "single-input token change succeeds at its independently derived minimum Ada" propMinimumBoundary
    ]

addresses :: Either Error (Address.Address, Address.Address)
addresses = do
  key <- Credential.keyHashFromBytes (B.replicate 28 7)
  stake <- Credential.keyHashFromBytes (B.replicate 28 8)
  script <- Credential.scriptHashFromBytes (B.replicate 28 9)
  pure (Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key)), Address.ShelleyAddress (Shelley.base Network.testnet (Credential.ScriptCredential script) (Credential.KeyCredential stake)))

-- The five input assets exclude mintedAsset by construction. Return the hint
-- asset explicitly as well, so fixture access remains total on every compiler.
assets :: Either Error ([Asset.AssetId], Asset.AssetId, Asset.AssetId)
assets = do
  policyA <- Policy.fromBytes (B.replicate 28 10)
  policyB <- Policy.fromBytes (B.replicate 28 11)
  short <- Name.fromBytes (B.singleton 0)
  long <- Name.fromBytes (B.replicate 32 255)
  let hintAsset = Asset.Native policyA Name.empty
      mintedAsset = Asset.Native policyB long
      inputAssets = [hintAsset, Asset.Native policyA short, Asset.Native policyA long, Asset.Native policyB Name.empty, Asset.Native policyB short]
  pure (inputAssets, mintedAsset, hintAsset)

quantities :: [Value.Value] -> Map.Map Asset.AssetId Integer
quantities = Map.filter (/= 0) . Map.fromListWith (+) . concatMap Value.toList

selectors :: Word64 -> [Selection.Selector]
selectors seed = [Selection.largestFirst, Selection.randomImproveWithSeed seed, Selection.randomImproveWithOptions seed Selection.Minimal]

-- Solve the independent Babbage size equation at its least fixed point, instead
-- of assuming that the minimum coin always uses the same CBOR width. Encoding
-- uses the public Haskell output codec; no native minimum-Ada oracle is called.
minimumAda :: Word64 -> Output.Output -> Either Error Integer
minimumAda cost output = go (0 :: Int) 0
  where
    tokens = filter ((/= Asset.Ada) . fst) (Value.toList (Output.value output))
    go iterations coin = do
      candidate <- Output.mkOutput (Output.address output) (Value.fromList ((Asset.Ada, coin) : tokens)) (Output.datum output) (Output.referenceScript output)
      let required = toInteger cost * (160 + toInteger (B.length (Output.encodeCbor candidate)))
      if required == coin
        then Right required
        else
          if iterations >= 10
            then Left (InvalidSelection "Independent minimum-Ada fixed point did not converge")
            else go (iterations + 1) required

assertLaws :: Word64 -> Selection.SelectionRequest -> Selection.Selection -> PropertyT IO ()
assertLaws cost request result = do
  let chosen = Selection.selected result
      remaining = Selection.remaining result
      refs = map Utxo.input
      chosenRefs = Set.fromList (refs chosen)
      remainingRefs = Set.fromList (refs remaining)
      candidates = Map.fromList [(Utxo.input item, item) | item <- Selection.available request]
      eligible = Map.union (Map.fromList [(Utxo.input item, item) | item <- Selection.preselected request]) candidates
      delta =
        Map.filter
          (/= 0)
          ( Map.unionsWith
              (+)
              [quantities (map (Output.value . Utxo.output) chosen), Map.map negate (quantities [Selection.target request]), Map.map negate (quantities (map Output.value (Selection.change result)))]
          )
  length chosen === Set.size chosenRefs
  length remaining === Set.size remainingRefs
  assert (Set.null (Set.intersection chosenRefs remainingRefs))
  remainingRefs === Set.difference (Map.keysSet candidates) chosenRefs
  assert (Set.fromList (refs (Selection.preselected request)) `Set.isSubsetOf` chosenRefs)
  forM_ (chosen <> remaining) $ \item -> do
    expected <- evalEither (maybe (Left (InvalidSelection "Ineligible input")) Right (Map.lookup (Utxo.input item) eligible))
    -- Identity and every resolved output field, including datum/script bytes,
    -- must survive both the selected and remaining paths.
    Output.encodeCbor (Utxo.output item) === Output.encodeCbor (Utxo.output expected)
  delta === Map.empty
  forM_ (Selection.change result) $ \output -> do
    Output.address output === Selection.changeAddress request
    assert (all ((>= 0) . snd) (Value.toList (Output.value output)))
    Output.datum output === Datum.NoDatum
    Output.referenceScript output === Nothing
    required <- evalEither (minimumAda cost output)
    assert (Value.quantity Asset.Ada (Output.value output) >= required)

propSignedSparse :: Property
propSignedSparse = property $ do
  (tokens, mintedAsset, hintAsset) <- evalEither assets
  (enterprise, base) <- evalEither addresses
  params <- evalEither Fixture.parameters
  count <- forAll (Gen.int (Range.linear 1 10))
  rows <- forAll (Gen.list (Range.singleton count) (Gen.list (Range.singleton 5) (Gen.integral (Range.linear 0 1000))))
  signs <- forAll (Gen.list (Range.singleton 5) Gen.bool)
  seed <- forAll (Gen.word64 Range.constantBounded)
  cost <- forAll (Gen.element [0, 1, 24, 100, 4310, 10000])
  coinTarget <- forAll (Gen.integral (Range.linear (-5000000) 5000000))
  mandatoryCount <- forAll (Gen.int (Range.linear 0 count))
  overlap <- forAll Gen.bool
  baseChange <- forAll Gen.bool
  hintMode <- forAll (Gen.int (Range.linear 0 2))
  identifier <- evalEither (Id.fromBytes (B.replicate 32 42))
  retained <- evalEither (Data.decodeCbor (B.pack [24, 1]))
  let destination = if baseChange then base else enterprise
      resolved index amounts = do
        let datum = case index `mod` 3 of 0 -> Datum.NoDatum; 1 -> Datum.InlineDatum retained; _ -> Datum.InlineDatum (Data.fromData (Data.List [Data.Integer (toInteger index)]))
            reference = if odd index then Just (Script.Native (Native.invalidBefore (fromIntegral index))) else Nothing
        output <- Output.mkOutput (if odd index then base else enterprise) (Value.fromList ((Asset.Ada, 50000000) : zip tokens amounts)) datum reference
        pure (Utxo.utxo (Input.input identifier (fromIntegral index)) output)
  pool <- evalEither (zipWithM resolved [0 :: Int ..] rows)
  let totalTokens = Map.delete Asset.Ada (quantities (map (Output.value . Utxo.output) pool))
      signed = [(token, if negative then negate (1 + Map.findWithDefault 0 token totalTokens `div` 2) else Map.findWithDefault 0 token totalTokens `div` 2) | (token, negative) <- zip tokens signs]
      target = Value.fromList ((Asset.Ada, coinTarget) : (mintedAsset, -1000) : signed)
      mandatory = take mandatoryCount pool
      available = if overlap then pool else drop mandatoryCount pool
  hint <- evalEither (Output.mkOutput destination (Value.fromList [(Asset.Ada, 1000000000), (hintAsset, 1000000)]) Datum.NoDatum Nothing)
  let hints = case hintMode of 0 -> Nothing; 1 -> Just []; _ -> Just [hint, hint]
  request <- evalEither (Selection.mkSelectionRequest (Selection.SelectionOptions mandatory available target hints destination (params {Parameters.parameterAdaPerUtxoByte = Just cost, Parameters.parameterMaxValueSize = Just 5000})))
  classify "mandatory only" (mandatoryCount == count && not overlap)
  classify "overlapping mandatory" (mandatoryCount > 0 && overlap)
  classify "implicit Ada source" (coinTarget < 0)
  classify "base change address" baseChange
  classify "hint amount exceeds available funding" (hintMode == 2)
  classify "sparse input bundle" (any (elem 0) rows)
  forM_ (selectors seed) $ \selector -> do
    result <- evalIO (Selection.select selector request) >>= evalEither
    assertLaws cost request result
    -- This asset occurs in no input: negative net requirements must materialize
    -- as token change, even when no optional input remains to select.
    Map.findWithDefault 0 mintedAsset (quantities (map Output.value (Selection.change result))) === 1000

propMinimumBoundary :: Property
propMinimumBoundary = property $ do
  (_, token, _) <- evalEither assets
  (enterprise, base) <- evalEither addresses
  params <- evalEither Fixture.parameters
  quantity <- forAll (Gen.element [1, 23, 24, 255, 256, 65535, 65536, 4294967296])
  cost <- forAll (Gen.element [1, 24, 100, 4310, 10000])
  baseChange <- forAll Gen.bool
  seed <- forAll (Gen.word64 Range.constantBounded)
  identifier <- evalEither (Id.fromBytes (B.replicate 32 43))
  let destination = if baseChange then base else enterprise
      inputCoin = 50000000
  inputOutput <- evalEither (Output.mkOutput enterprise (Value.fromList [(Asset.Ada, inputCoin), (token, quantity)]) Datum.NoDatum Nothing)
  changeShape <- evalEither (Output.mkOutput destination (Value.singleton token quantity) Datum.NoDatum Nothing)
  minimumCoin <- evalEither (minimumAda cost changeShape)
  let mandatory = Utxo.utxo (Input.input identifier maxBound) inputOutput
      request coin = Selection.mkSelectionRequest (Selection.SelectionOptions [mandatory] [] (Value.lovelace (inputCoin - coin)) Nothing destination (params {Parameters.parameterAdaPerUtxoByte = Just cost, Parameters.parameterMaxValueSize = Just 5000}))
  adequate <- evalEither (request minimumCoin)
  inadequate <- evalEither (request (minimumCoin - 1))
  classify "one-byte minimum coin" (minimumCoin < 24)
  classify "three-byte minimum coin" (minimumCoin >= 256 && minimumCoin < 65536)
  classify "five-byte minimum coin" (minimumCoin >= 65536)
  forM_ (selectors seed) $ \selector -> do
    failed <- evalIO (Selection.select selector inadequate)
    case failed of
      Left (NativeError _ code _) -> Code.toNumber code === 1100
      _ -> assert False
    result <- evalIO (Selection.select selector adequate) >>= evalEither
    assertLaws cost adequate result
    quantities (map Output.value (Selection.change result)) === quantities [Value.fromList [(Asset.Ada, minimumCoin), (token, quantity)]]
