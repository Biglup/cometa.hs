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
{-# LANGUAGE ScopedTypeVariables #-}

-- | Every provider callback is exercised through actual typed native dispatch.
module Provider (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import Cometa.AssetId (AssetId (..))
import qualified Cometa.AssetName as AssetName
import Cometa.Error (Error (..))
import qualified Cometa.Evaluation as Evaluation
import Cometa.Internal.FFI.Native (NativeCode)
import qualified Cometa.Internal.FFI.ProviderRuntime as FFI
import qualified Cometa.Internal.ProviderRuntime as Native
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor
import qualified Cometa.PlutusData as Data
import qualified Cometa.PolicyId as Policy
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Provider as Provider
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket_, fromException, try)
import Control.Monad (forM_, replicateM_, void)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word32, Word8)
import qualified Fixtures.ProtocolParameters as Parameters
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- TYPES ----------------------------------------------------------------------

data Fixture = Fixture Address.Address Reward.RewardAddress AssetId Utxo.Utxo Datum.Hash32 Tx.Transaction TxId.TransactionId Evaluation.Budgets

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Provider injection"
    [ testCase "all ten callbacks marshal typed values through native provider methods" correspondence,
      testCase "unsupported capabilities preserve exact errors through native failures" unsupported,
      testCase "missing datum and NFT remain successful Nothing, and empty queries remain empty" missing,
      testCase "name byte bounds reject before acquiring registrations" metadata,
      testCase "typed snapshots outlive native cleanup and repeated GC" lifetime,
      testCase "lazy query results and callback exceptions unwind before releasing owners" exceptions,
      testCase "native confirmation cancellation joins callback cleanup and recovers" cancellation,
      testCase "trailing requests avoid handlers and partial malformed replies release typed owners" malformed
    ]

fixture :: Either Error Fixture
fixture = do
  address <- Address.fromBytes (B.cons 0x61 (B.replicate 28 1))
  reward <- Reward.fromBytes (B.cons 0xe1 (B.replicate 28 2))
  policy <- Policy.fromBytes (B.replicate 28 3)
  token <- AssetName.fromBytes "token"
  identifier <- TxId.fromBytes (B.replicate 32 4)
  output <- Output.mkOutput address (Cometa.Value.lovelace 2000000) Datum.NoDatum Nothing
  hash <- Datum.hashFromBytes (B.replicate 32 5)
  let reference = Input.input identifier maxBound
      resolved = Utxo.utxo reference output
      redeemer = Redeemer.Redeemer Redeemer.Spending 0 (Data.fromData (Data.Integer 42)) (ExUnits 1 2)
  encodedBody <- Body.fromBody (Body.body [] [] 10)
  witnesses <- Witnesses.mkWitnesses [] [] [] [] [redeemer]
  let transaction = Tx.assemble encodedBody (Witnesses.fromWitnesses witnesses) Nothing
  budgets <- Evaluation.mkBudgets [(Evaluation.RedeemerId Redeemer.Spending 0, ExUnits 100 200)]
  pure (Fixture address reward (Native policy token) resolved hash transaction identifier budgets)

backend :: Fixture -> Provider.Provider
backend (Fixture address reward asset resolved hash transaction identifier budgets) =
  (Provider.unavailable "Fixture provider" 42)
    { Provider.protocolParameters = pure Parameters.parameters,
      Provider.utxosAt = \actual -> do
        actual @?= address
        pure (Right [resolved]),
      Provider.rewardBalance = \actual -> do
        actual @?= reward
        pure (Right maxBound),
      Provider.utxosWithAsset = \actual selected -> do
        actual @?= address
        selected @?= asset
        pure (Right [resolved]),
      Provider.utxoWithAsset = \selected -> do
        selected @?= asset
        pure (Right (Just resolved)),
      Provider.resolveInputs = \references -> do
        references @?= [Utxo.input resolved]
        pure (Right [resolved]),
      Provider.resolveDatum = \actual -> do
        actual @?= hash
        pure (Right (Just (Data.fromData (Data.Integer 42)))),
      Provider.awaitTransaction = \actual timeoutMillis -> do
        actual @?= identifier
        timeoutMillis @?= maxBound
        pure (Right True),
      Provider.submitTransaction = \actual -> do
        Tx.body actual @?= Tx.body transaction
        pure (Right identifier),
      Provider.evaluateTransaction = \actual additional -> do
        Tx.body actual @?= Tx.body transaction
        additional @?= [resolved]
        pure (Right budgets)
    }

correspondence :: IO ()
correspondence = do
  values@(Fixture address reward asset resolved hash transaction identifier budgets) <- requirePure fixture
  expectedParameters <- requirePure Parameters.parameters
  result <- Native.withProvider (backend values) $ \adapter -> do
    let provider = Native.nativeProvider adapter
    Provider.name provider @?= "Fixture provider"
    Provider.networkMagic provider @?= 42
    Provider.protocolParameters provider >>= (@?= Right expectedParameters)
    Provider.utxosAt provider address >>= (@?= Right [resolved])
    Provider.rewardBalance provider reward >>= (@?= Right maxBound)
    Provider.utxosWithAsset provider address asset >>= (@?= Right [resolved])
    Provider.utxoWithAsset provider asset >>= (@?= Right (Just resolved))
    Provider.resolveInputs provider [Utxo.input resolved] >>= (@?= Right [resolved])
    Provider.resolveDatum provider hash >>= (@?= Right (Just (Data.fromData (Data.Integer 42))))
    Provider.awaitTransaction provider identifier maxBound >>= (@?= Right True)
    Provider.submitTransaction provider transaction >>= (@?= Right identifier)
    Provider.evaluateTransaction provider transaction [resolved] >>= (@?= Right budgets)
    pure (Right ())
  result @?= Right ()

unsupported :: IO ()
unsupported = do
  Fixture address reward asset resolved hash transaction identifier _ <- requirePure fixture
  result <- Native.withProvider (Provider.unavailable "Unavailable" 7) $ \adapter -> do
    let provider = Native.nativeProvider adapter
        unit :: IO (Either Error a) -> IO (Either Error ())
        unit = fmap void
        operations =
          [ ("protocolParameters", unit (Provider.protocolParameters provider)),
            ("utxosAt", unit (Provider.utxosAt provider address)),
            ("rewardBalance", unit (Provider.rewardBalance provider reward)),
            ("utxosWithAsset", unit (Provider.utxosWithAsset provider address asset)),
            ("utxoWithAsset", unit (Provider.utxoWithAsset provider asset)),
            ("resolveInputs", unit (Provider.resolveInputs provider [Utxo.input resolved])),
            ("resolveDatum", unit (Provider.resolveDatum provider hash)),
            ("awaitTransaction", unit (Provider.awaitTransaction provider identifier 0)),
            ("submitTransaction", unit (Provider.submitTransaction provider transaction)),
            ("evaluateTransaction", unit (Provider.evaluateTransaction provider transaction [resolved]))
          ]
    forM_ operations $ \(operation, action) -> action >>= (@?= Left (UnsupportedOperation ("provider." <> operation)))
    pure (Right ())
  result @?= Right ()

missing :: IO ()
missing = do
  Fixture address _ asset resolved hash _ _ _ <- requirePure fixture
  let provider =
        (Provider.unavailable "Empty" 8)
          { Provider.utxosAt = \_ -> pure (Right []),
            Provider.resolveInputs = \_ -> pure (Right []),
            Provider.utxoWithAsset = \_ -> pure (Right Nothing),
            Provider.resolveDatum = \_ -> pure (Right Nothing)
          }
  result <- Native.withProvider provider $ \adapter -> do
    let native = Native.nativeProvider adapter
    Provider.utxosAt native address >>= (@?= Right [])
    Provider.resolveInputs native [Utxo.input resolved] >>= (@?= Right [])
    Provider.utxoWithAsset native asset >>= (@?= Right Nothing)
    Provider.resolveDatum native hash >>= (@?= Right Nothing)
    pure (Right ())
  result @?= Right ()

metadata :: IO ()
metadata = do
  baseline <- Runtime.liveContexts
  forM_ [Text.replicate 256 "a", Text.replicate 128 "é", "bad\0name"] $ \backendName -> do
    result <- Native.withProvider (Provider.unavailable backendName 1) (\_ -> assertFailure "invalid metadata acquired a callback" >> pure (Right ()))
    assertBool "invalid name accepted" (isLeft result)
  let validName = Text.replicate 127 "é" <> "a"
  nativeMetadata <- Native.withProvider (Provider.unavailable validName maxBound) $ \adapter -> Native.withNative adapter $ \pointer ->
    allocaBytes 256 $ \nameOutput -> alloca $ \magicOutput -> do
      status <- cMetadata pointer nameOutput 256 magicOutput
      status @?= 0
      actualName <- B.packCString (castPtr nameOutput)
      actualMagic <- peek magicOutput
      actualName @?= Text.encodeUtf8 validName
      actualMagic @?= maxBound
      pure (Right ())
  nativeMetadata @?= Right ()
  Runtime.liveContexts >>= (@?= baseline)

lifetime :: IO ()
lifetime = do
  values@(Fixture address _ _ resolved _ _ _ _) <- requirePure fixture
  baseline <- Runtime.liveContexts
  result <- Native.withProvider (backend values) $ \adapter -> do
    let provider = Native.nativeProvider adapter
    replicateM_ 20 (performGC >> Provider.utxosAt provider address >>= (@?= Right [resolved]))
    Provider.utxosAt provider address
  performGC
  result @?= Right [resolved]
  Runtime.liveContexts >>= (@?= baseline)

exceptions :: IO ()
exceptions = do
  Fixture address _ _ _ _ _ _ _ <- requirePure fixture
  baseline <- Runtime.liveContexts
  forM_ [pure (Right (error "lazy UTxO list")), ioError (userError "query exception")] $ \query -> do
    let provider = (Provider.unavailable "Throwing" 42) {Provider.utxosAt = const query}
    outcome <- try (Native.withProvider provider (\adapter -> Provider.utxosAt (Native.nativeProvider adapter) address)) :: IO (Either SomeException (Either Error [Utxo.Utxo]))
    assertBool "query exception swallowed" (isLeft outcome)
  Runtime.liveContexts >>= (@?= baseline)

cancellation :: IO ()
cancellation = do
  Fixture _ _ _ _ _ _ identifier _ <- requirePure fixture
  started <- newEmptyMVar
  finalized <- newEmptyMVar
  hold <- newEmptyMVar
  count <- newIORef (0 :: Int)
  let await _ _ = do
        calls <- readIORef count
        modifyIORef' count (+ 1)
        if calls == 0
          then bracket_ (putMVar started ()) (putMVar finalized ()) (takeMVar hold)
          else pure (Right True)
      provider = (Provider.unavailable "Cancelable" 42) {Provider.awaitTransaction = await}
  result <- Native.withProvider provider $ \adapter -> do
    let native = Native.nativeProvider adapter
    finished <- newEmptyMVar
    worker <- forkFinally (Provider.awaitTransaction native identifier 10) (putMVar finished)
    takeMVar started
    Provider.awaitTransaction native identifier 10 >>= (@?= Left RuntimeBusy)
    joined <- timeout 5000000 (killThread worker >> takeMVar finished)
    case joined of
      Just (Left exception) -> fromException exception @?= Just ThreadKilled
      _ -> assertFailure "provider cancellation failed to join"
    takeMVar finalized
    Provider.awaitTransaction native identifier 10
  result @?= Right True

malformed :: IO ()
malformed = do
  Fixture address _ _ resolved _ _ _ _ <- requirePure fixture
  baseline <- Runtime.liveContexts
  calls <- newIORef (0 :: Int)
  reply <- newIORef (B.singleton 0x80)
  let handler _ _ = modifyIORef' calls (+ 1) >> Right <$> readIORef reply
      request = Cometa.Internal.TransactionCbor.encode (Codec.CBOR.Encoding.encodeBytes (Address.toBytes address))
  result <- Runtime.withRuntime handler $ \owner -> do
    badRequest <- rawCall owner 1 (request <> B.singleton 0)
    assertBool "trailing native request accepted" (isLeft badRequest)
    readIORef calls >>= (@?= 0)
    writeIORef reply (B.singleton 0x82 <> Utxo.encodeCbor resolved <> B.singleton 0)
    replicateM_ 10 $ do
      partial <- rawCall owner 1 request
      assertBool "partial malformed reply accepted" (isLeft partial)
    writeIORef reply (B.singleton 0x80)
    rawCall owner 1 request
  result @?= Right (B.singleton 0x80)
  Runtime.liveContexts >>= (@?= baseline)

rawCall :: Runtime.Runtime -> Word32 -> B.ByteString -> IO (Either Error B.ByteString)
rawCall owner operation request = Runtime.withOperation owner $ \context ->
  Runtime.withBytes "Malformed fixture" $ \backendName nameSize -> Runtime.withBytes request $ \bytes size ->
    Runtime.withOwnedBuffer "test.provider.raw" (FFI.cCall context backendName nameSize 42 operation bytes size)

requirePure :: (Show failure) => Either failure a -> IO a
requirePure = either (\failure -> assertFailure (show failure) >> fail "provider fixture") pure

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_provider_metadata"
  cMetadata :: Ptr FFI.NativeProvider -> Ptr Word8 -> CSize -> Ptr Word32 -> IO NativeCode
