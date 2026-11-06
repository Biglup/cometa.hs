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

module PublicTransaction (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PrivateKey as Private
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.Crypto.Ed25519.PublicKey as Public
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import qualified Cometa.Encoding.Cbor as Cbor
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.KeyHandler.Software as Software
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), IOException, bracket_, fromException, try)
import Control.Monad (forM_, replicateM_, void, (>=>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text
import Data.Word (Word64, Word8)
import qualified Fixtures.Transaction as Fixture
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import System.Mem (performGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Public transaction workflows"
    [ testCase "pinned signed corpus exact bytes, typed fee and native ID agreement" corpus,
      testCase "all field orders and nonminimal/indefinite outer arrays preserve identity" framing,
      testCase "same-value body edits are exact no-ops and changed fees clear only outer signatures" edits,
      testCase "partial signatures preserve original body and wrapper and agree with native signing" signing,
      testCase "invalid complete envelopes and trailing bytes fail" invalid,
      testCase "software normal and extended handlers return partial witnesses without mutating input" software,
      testCase "hierarchical handler signs typed nonempty paths" hierarchical,
      testCase "closed, wrong-password and callback failures preserve the input and release resources" failures,
      testCase "signing callback cancellation joins cleanup and handler remains usable" cancellation,
      testCase "sub-transaction signs its own body and retains exact framing" subTransaction
    ]

corpus :: IO ()
corpus = forM_ Fixture.allFixtures $ \fixture -> do
  bytes <- hex (Fixture.transactionHex fixture)
  transaction <- requirePure (Tx.decodeCbor bytes)
  Tx.encodeCbor transaction @?= bytes
  Hex.encodeHex (Body.toCbor (Tx.body transaction)) @?= Fixture.bodyHex fixture
  Hex.encodeHex (Witnesses.toCbor (Tx.witnesses transaction)) @?= Fixture.witnessHex fixture
  Body.fee (Body.toBody (Tx.body transaction)) @?= Fixture.expectedFee fixture
  digest <- require (Tx.transactionId transaction)
  TxId.toHex digest @?= Fixture.hashHex fixture
  (nativeFee, nativeHash, counts) <- nativeSnapshot bytes
  nativeFee @?= Fixture.expectedFee fixture
  nativeHash @?= TxId.toBytes digest
  counts @?= Fixture.expectedCounts fixture
  Tx.hasScriptData transaction @?= (Fixture.fixtureName fixture == Fixture.fixtureName Fixture.rich)

framing :: IO ()
framing = do
  original <- fixtureTransaction Fixture.noncanonical
  rich <- fixtureTransaction Fixture.rich
  let components = Body.toCbor (Tx.body original) <> Witnesses.toCbor (Tx.witnesses original)
      layouts =
        [ (Tx.Historical, B.singleton 0x83 <> components <> B.singleton 0xf6),
          (Tx.Mempool, B.singleton 0x84 <> components <> B.pack [0xf5, 0xf6]),
          (Tx.Mempool, B.singleton 0x84 <> components <> B.pack [0xf4, 0xf6]),
          (Tx.Block, B.singleton 0x84 <> components <> B.pack [0xf6, 0xf5]),
          (Tx.Block, B.singleton 0x84 <> components <> B.pack [0xf6, 0xf4])
        ]
      variants (layout, bytes) =
        [ (layout, bytes),
          (layout, B.singleton 0x9f <> B.drop 1 bytes <> B.singleton 0xff),
          (layout, B.pack [0x98, B.head bytes - 0x80] <> B.drop 1 bytes)
        ]
  forM_ (concatMap variants layouts) $ \(layout, bytes) -> do
    transaction <- requirePure (Tx.decodeCbor bytes)
    Tx.encodeCbor transaction @?= bytes
    Tx.frame transaction @?= layout
    let attached = Tx.setAuxiliaryData (Tx.auxiliaryData rich) transaction
    Tx.body attached @?= Tx.body transaction
    Tx.witnesses attached @?= Tx.witnesses transaction
    Tx.setAuxiliaryData Nothing attached @?= transaction
    requirePure (Tx.decodeCbor (Tx.encodeCbor attached)) >>= (@?= attached)
    let fresh = Tx.assemble (Tx.body transaction) (Tx.witnesses transaction) (Tx.auxiliaryData rich)
    requirePure (Tx.decodeCbor (Tx.encodeCbor fresh)) >>= (@?= fresh)
    let changedClaim = Tx.setScriptValidity (not (Tx.scriptValidity transaction)) transaction
    Tx.setScriptValidity (Tx.scriptValidity transaction) transaction @?= transaction
    Tx.body changedClaim @?= Tx.body transaction
    Tx.witnesses changedClaim @?= Tx.witnesses transaction
    Tx.scriptValidity changedClaim @?= not (Tx.scriptValidity transaction)
    requirePure (Tx.decodeCbor (Tx.encodeCbor changedClaim)) >>= (@?= changedClaim)
    nativeSnapshot (Tx.encodeCbor changedClaim) >>= \(_, digest, _) -> Hex.encodeHex digest @?= Fixture.hashHex Fixture.noncanonical
    nativeSnapshot bytes >>= \(_, digest, _) -> Hex.encodeHex digest @?= Fixture.hashHex Fixture.noncanonical
    Tx.encodeCbor (Tx.setFee 10 transaction) @?= bytes
    signed <- require (Key.withNormalKey seed (`Signing.sign` transaction))
    Body.toCbor (Tx.body signed) @?= Body.toCbor (Tx.body transaction)
    Tx.frame signed @?= layout
    assertBool "outer header changed" (B.take (if B.head bytes == 0x98 then 2 else 1) (Tx.encodeCbor signed) == B.take (if B.head bytes == 0x98 then 2 else 1) bytes)
    assertBool "outer indefinite ending changed" (B.last (Tx.encodeCbor signed) == B.last bytes)

edits :: IO ()
edits = forM_ Fixture.allFixtures $ \fixture -> do
  transaction <- fixtureTransaction fixture
  normalized <- requirePure (Body.fromBody (Body.toBody (Tx.body transaction)))
  let unchanged = Tx.setBody normalized transaction
      changed = Tx.setFee 42 transaction
      changedAgain = Tx.setFee 43 transaction
  unchanged @?= transaction
  Tx.setFee (Fixture.expectedFee fixture) transaction @?= transaction
  Body.fee (Body.toBody (Tx.body changed)) @?= 42
  Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses changed)) @?= []
  Witnesses.bootstrapWitnesses (Witnesses.toWitnesses (Tx.witnesses changed)) @?= []
  before <- witnessFields transaction
  after <- witnessFields changed
  after @?= filter (\(key, _) -> key /= 0 && key /= 2) before
  Tx.auxiliaryData changed @?= Tx.auxiliaryData transaction
  first <- require (Tx.transactionId changed)
  second <- require (Tx.transactionId changedAgain)
  assertBool "independent fee edits share an ID" (first /= second)
  expected <- hex (Fixture.transactionHex fixture)
  Tx.encodeCbor transaction @?= expected
  requirePure (Tx.decodeCbor (Tx.encodeCbor changed)) >>= (@?= changed)

signing :: IO ()
signing = do
  transaction <- fixtureTransaction Fixture.noncanonical
  witness <- require (Key.withNormalKey seed (`Signing.verificationWitness` transaction))
  expected <- nativeSign 0 (Tx.encodeCbor transaction)
  Public.toBytes (Witness.publicKey witness) <> Signature.toBytes (Witness.signature witness) @?= expected
  signed <- require (Key.withNormalKey seed (`Signing.sign` transaction))
  twice <- require (Key.withNormalKey seed (`Signing.sign` signed))
  twice @?= signed
  Tx.body signed @?= Tx.body transaction
  Tx.transactionId signed >>= (\digest -> Tx.transactionId transaction >>= (@?= digest))
  digest <- require (Tx.transactionId signed)
  Public.verify (Witness.publicKey witness) (TxId.toBytes digest) (Witness.signature witness) >>= (@?= Right True)
  (_, _, counts) <- nativeSnapshot (Tx.encodeCbor signed)
  assertBool "new signature not verified by native oracle" (last counts > last (Fixture.expectedCounts Fixture.noncanonical))
  let invalidated = Tx.setFee 42 signed
  Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses invalidated)) @?= []
  before <- witnessFields transaction
  after <- witnessFields signed
  filter ((/= 0) . fst) before @?= filter ((/= 0) . fst) after

invalid :: IO ()
invalid = do
  transaction <- fixtureTransaction Fixture.noncanonical
  forM_ [B.empty, B.singleton 0, B.take 1 (Tx.encodeCbor transaction), B.init (Tx.encodeCbor transaction), Tx.encodeCbor transaction <> B.singleton 0] $ \bytes ->
    assertBool "invalid envelope accepted" (isLeft (Tx.decodeCbor bytes))
  forM_ ["82a0a0", "84a0a0f5f6", "84a3008001800220a0f5f6", "84a3008001800200a0f6f6", "9fa3008001800200a0f6f5f5ff"] $ hex >=> (assertBool "invalid schema accepted" . isLeft . Tx.decodeCbor)

software :: IO ()
software = do
  transaction <- fixtureTransaction Fixture.rich
  forM_ [False, True] $ \extended -> do
    let withKey action = if extended then Key.withExtendedKey (B.replicate 64 1) action else Key.withNormalKey seed action
    witness <- require (withKey (`Signing.verificationWitness` transaction))
    partial <- require (withKey (\key -> Software.withSigningKey key password (pure password) (`Software.signTransaction` transaction)))
    Witnesses.verificationWitnesses (Witnesses.toWitnesses partial) @?= [witness]
    signed <- requirePure (Tx.addWitnesses partial transaction)
    Tx.body signed @?= Tx.body transaction
    requirePure (Tx.decodeCbor (Tx.encodeCbor signed)) >>= (@?= signed)
    replicateM_ 5 (void (require (withKey (\key -> Software.withSigningKey key password (performGC >> pure password) (`Software.signTransaction` transaction)))))

hierarchical :: IO ()
hierarchical = do
  transaction <- fixtureTransaction Fixture.noncanonical
  let entropy = B.replicate 16 0
      path = Path.derivationPath (Path.standardAccountPath minBound) Path.externalRole minBound
  witness <- require (Private.withEntropy "" entropy (\root -> Private.withDerived root (Path.toIndices path) (\child -> Private.withSigningKey child (`Signing.verificationWitness` transaction))))
  partial <- require (Software.withEntropy entropy password (pure password) (\handler -> Software.signTransactionAt handler (path :| [path]) transaction))
  Witnesses.verificationWitnesses (Witnesses.toWitnesses partial) @?= [witness]

failures :: IO ()
failures = do
  transaction <- fixtureTransaction Fixture.noncanonical
  escaped <- newEmptyMVar
  _ <- require (Key.withNormalKey seed (\key -> putMVar escaped key >> pure (Right ())))
  closed <- takeMVar escaped
  Signing.sign closed transaction >>= (@?= Left SigningKeyClosed)
  handlerSlot <- newEmptyMVar
  _ <- require (withHandler (pure password) (\handler -> putMVar handlerSlot handler >> pure (Right ())))
  handler <- takeMVar handlerSlot
  Software.signTransaction handler transaction >>= (@?= Left KeyHandlerClosed)
  wrong <- withHandler (pure "wrong-password") (`Software.signTransaction` transaction)
  assertBool "wrong password accepted" (isLeft wrong)
  invalidPassword <- withHandler (pure B.empty) (`Software.signTransaction` transaction)
  invalidPassword @?= Left (InvalidKeyHandlerPasswordLength 0)
  ref <- newIORef Nothing
  callbackResult <- newIORef Nothing
  let request = do
        active <- readIORef ref
        case active of
          Nothing -> assertFailure "missing handler" >> pure password
          Just value -> do
            result <- Software.signTransaction value transaction
            modifyIORef' callbackResult (const (Just result))
            pure password
  _ <- require (withHandler request (\active -> modifyIORef' ref (const (Just active)) >> Software.signTransaction active transaction))
  readIORef callbackResult >>= (@?= Just (Left KeyHandlerBusy))
  failureCount <- newIORef (0 :: Int)
  let sometimesFails = do
        n <- readIORef failureCount
        modifyIORef' failureCount (+ 1)
        if n == 0 then ioError (userError "password action failed") else pure password
  _ <-
    require
      ( withHandler sometimesFails $ \active -> do
          first <- try (Software.signTransaction active transaction) :: IO (Either IOException (Either Error Witnesses.EncodedWitnesses))
          assertBool "callback exception swallowed" (isLeft first)
          Software.signTransaction active transaction
      )
  expected <- hex (Fixture.transactionHex Fixture.noncanonical)
  Tx.encodeCbor transaction @?= expected

cancellation :: IO ()
cancellation = do
  transaction <- fixtureTransaction Fixture.noncanonical
  started <- newEmptyMVar
  finalized <- newEmptyMVar
  hold <- newEmptyMVar
  count <- newIORef (0 :: Int)
  let request = do
        n <- readIORef count
        modifyIORef' count (+ 1)
        if n == 0 then bracket_ (putMVar started ()) (putMVar finalized ()) (takeMVar hold) else pure password
  result <- withHandler request $ \handler -> do
    finished <- newEmptyMVar
    worker <- forkFinally (Software.signTransaction handler transaction) (putMVar finished)
    takeMVar started
    Software.signTransaction handler transaction >>= (@?= Left KeyHandlerBusy)
    joined <- timeout 5000000 (killThread worker >> takeMVar finished)
    case joined of
      Just (Left exception) -> fromException exception @?= Just ThreadKilled
      _ -> assertFailure "signing cancellation failed to join"
    takeMVar finalized
    Software.signTransaction handler transaction
  assertBool "handler failed after cancellation" (not (isLeft result))

subTransaction :: IO ()
subTransaction = do
  transaction <- requirePure (Sub.decodeCbor (B.pack [0x9f, 0xa2, 0, 0x80, 1, 0x80, 0xa0, 0xf6, 0xff]))
  signed <- require (Key.withNormalKey seed (`Signing.signSubTransaction` transaction))
  Sub.body signed @?= Sub.body transaction
  B.head (Sub.encodeCbor signed) @?= 0x9f
  B.last (Sub.encodeCbor signed) @?= 0xff
  witness <- require (Key.withNormalKey seed (`Signing.subTransactionWitness` transaction))
  expected <- nativeSign 1 (Sub.encodeCbor transaction)
  Public.toBytes (Witness.publicKey witness) <> Signature.toBytes (Witness.signature witness) @?= expected
  generated <- require (withHandler (pure password) (`Software.signSubTransaction` transaction))
  Witnesses.verificationWitnesses (Witnesses.toWitnesses generated) @?= [witness]
  normalized <- requirePure (SubBody.fromBody (SubBody.toBody (Sub.body signed)))
  Sub.setBody normalized signed @?= signed
  let enclosingBody = (Body.body [] [] 10) {Body.bodySubTransactions = Just [signed]}
  encodedOuter <- requirePure (Body.fromBody enclosingBody)
  let outer = Tx.fromBody encodedOuter
  outerSigned <- require (Key.withNormalKey seed (`Signing.sign` outer))
  let edited = Tx.setFee 42 outerSigned
  Body.bodySubTransactions (Body.toBody (Tx.body edited)) @?= Just [signed]
  Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses edited)) @?= []
  reloaded <- requirePure (Tx.decodeCbor (Tx.encodeCbor edited))
  Body.bodySubTransactions (Body.toBody (Tx.body reloaded)) @?= Just [signed]
  let path = Path.derivationPath (Path.standardAccountPath minBound) Path.externalRole minBound
  hierarchicalPartial <- require (Software.withEntropy (B.replicate 16 0) password (pure password) (\handler -> Software.signSubTransactionAt handler (path :| []) transaction))
  digest <- require (Sub.transactionId transaction)
  forM_ (Witnesses.verificationWitnesses (Witnesses.toWitnesses hierarchicalPartial)) $ \value ->
    Public.verify (Witness.publicKey value) (TxId.toBytes digest) (Witness.signature value) >>= (@?= Right True)

seed :: ByteString
seed = B.replicate 32 42

password :: ByteString
password = "transaction-fixture"

withHandler :: IO ByteString -> (Software.Handler Software.Ed25519 -> IO (Either Error value)) -> IO (Either Error value)
withHandler request action = Key.withNormalKey seed (\key -> Software.withSigningKey key password request action)

fixtureTransaction :: Fixture.Fixture -> IO Tx.Transaction
fixtureTransaction fixture = hex (Fixture.transactionHex fixture) >>= requirePure . Tx.decodeCbor

hex :: Data.Text.Text -> IO ByteString
hex text = maybe (assertFailure "invalid fixture hex" >> fail "fixture") pure (Hex.decodeHex text)

require :: (Show failure) => IO (Either failure value) -> IO value
require action = action >>= requirePure

requirePure :: (Show failure) => Either failure value -> IO value
requirePure = either (\failure -> assertFailure (show failure) >> fail "fixture operation") pure

witnessFields :: Tx.Transaction -> IO [(Integer, ByteString)]
witnessFields transaction = do
  encoded <- require (Cbor.fromBytes (Witnesses.toCbor (Tx.witnesses transaction)))
  pairs <- require (Cbor.decodeMap encoded)
  mapM (\(key, value) -> do number <- require (Cbor.decodeInteger key); pure (number, Cbor.toBytes value)) pairs

nativeSnapshot :: ByteString -> IO (Word64, ByteString, [Word64])
nativeSnapshot bytes = B.useAsCStringLen bytes $ \(input, size) ->
  alloca $ \fee -> allocaBytes 32 $ \digest -> allocaArray 6 $ \counts -> do
    status <- cOracle (castPtr input) (fromIntegral size) fee digest counts
    status @?= 0
    (,,) <$> peek fee <*> B.packCStringLen (castPtr digest, 32) <*> peekArray 6 counts

nativeSign :: CUInt -> ByteString -> IO ByteString
nativeSign sub bytes = B.useAsCStringLen bytes $ \(input, size) -> B.useAsCString seed $ \key -> allocaBytes 96 $ \output -> do
  status <- cNativeSign (castPtr input) (fromIntegral size) sub (castPtr key) output
  status @?= 0
  B.packCStringLen (castPtr output, 96)

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_transaction_oracle"
  cOracle :: Ptr Word8 -> CSize -> Ptr Word64 -> Ptr Word8 -> Ptr Word64 -> IO CUInt

foreign import ccall safe "cometa_test_transaction_sign"
  cNativeSign :: Ptr Word8 -> CSize -> CUInt -> Ptr Word8 -> Ptr Word8 -> IO CUInt
