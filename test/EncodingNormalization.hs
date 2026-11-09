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

-- | Explicit representation changes and immutable identity-bearing snapshots.
-- All fixtures are synthetic public data. The fixed signing seed is test-only;
-- no live wallet or ledger acceptance is involved.
module EncodingNormalization (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Encoding as E
import qualified Cometa.AssetId as Asset
import qualified Cometa.AssetName as Name
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Hash
import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
import qualified Cometa.Encoding.Cbor as Encoded
import qualified Cometa.Encoding.Collections as Collections
import qualified Cometa.Encoding.Reencode as Reencode
import Cometa.Encoding.Set (SetEncoding (TaggedSet, UntaggedSet))
import Cometa.Error (Error (InvalidValueQuantity))
import Cometa.Internal.FFI.Native (NativeCode)
import qualified Cometa.Internal.Runtime as Runtime
import qualified Cometa.Internal.TransactionCbor as Cbor
import qualified Cometa.PolicyId as Policy
import qualified Cometa.Script.Native as Native
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Fields as Fields
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Value
import qualified Cometa.Value.Raw as Raw
import Control.Monad (forM_, replicateM, (>=>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Encoding normalization and signed identity"
    [ testCase "raw value clones preserve signed coin, zeros, duplicates and empty groups" rawSnapshots,
      testCase "encoded input tag observer differs from native dirty-cache heuristic" bodySetMode,
      testCase "fresh scripts match cache clearing with definite child-list policy" scripts,
      testCase "script-list clearing normalizes descendants and preserves its envelope" scriptLists,
      testCase "composite cache clearing preserves indefinite child-list policy" scriptPolicies,
      testCase "native transaction cache clearing changes signed identity" transactions,
      testCase "native subtransaction cache clearing changes only that intent's identity" subTransactions,
      testCase "deep-cloned digest bytes survive source release and encoding changes" hashSnapshots,
      testCase "malformed oracle inputs release all partial owners" failures
    ]

must :: (Show error) => Either error value -> IO value
must = either (\failure -> assertFailure (show failure) >> fail "fixture") pure

normalize :: CUInt -> ByteString -> IO (Either Error ByteString)
normalize kind bytes = Runtime.withBytes bytes $ \input size -> Runtime.withOwnedBuffer "test.encoding.normalize" (cNormalize kind input size)

freshScript :: Native.NativeScript -> Either Error Native.NativeScript
freshScript = Native.fromJson . Native.toJson

scriptFixtures :: IO [Native.NativeScript]
scriptFixtures = do
  payment <- must (Credential.keyHashFromBytes (B.replicate 28 1))
  guard <- must (Credential.keyHashFromBytes (B.replicate 28 2))
  script <- must (Credential.scriptHashFromBytes (B.replicate 28 3))
  let leaves = [Native.signature payment, Native.invalidBefore 7, Native.invalidAfter maxBound, Native.requireGuard (Credential.KeyCredential guard), Native.requireGuard (Credential.ScriptCredential script)]
      composites = [Native.allOf leaves, Native.anyOf (reverse leaves), Native.atLeast 2 [Native.anyOf leaves, Native.allOf leaves, Native.invalidBefore 0]]
  traverse (must . Native.decodeCbor . nonminimalScript) (leaves <> composites)

-- Deliberately indefinite node arrays and nonminimal discriminants.
-- Child collections use definite policy here; the separate policy regression
-- exercises the native flag which construction JSON does not retain.
-- Child order and duplicate conditions retain their semantic significance.
nonminimalScript :: Native.NativeScript -> ByteString
nonminimalScript script = indefinite $ case Native.view script of
  Native.RequireSignature key -> tag 0 <> Cbor.encode (E.encodeBytes (Credential.keyHashBytes key))
  Native.RequireAll children -> tag 1 <> childrenBytes children
  Native.RequireAny children -> tag 2 <> childrenBytes children
  Native.RequireAtLeast required children -> tag 3 <> Cbor.encode (E.encodeWord64 required) <> childrenBytes children
  Native.InvalidBefore slot -> tag 4 <> Cbor.encode (E.encodeWord64 slot)
  Native.InvalidAfter slot -> tag 5 <> Cbor.encode (E.encodeWord64 slot)
  Native.RequireGuard credential -> tag 6 <> Credential.encodeCbor credential
  where
    tag number = B.pack [0x18, number]
    childrenBytes children = Cbor.encode (E.encodeListLen (fromIntegral (length children))) <> foldMap nonminimalScript children

indefinite :: ByteString -> ByteString
indefinite payload = B.singleton 0x9f <> payload <> B.singleton 0xff

scripts :: IO ()
scripts = do
  values <- scriptFixtures
  forM_ values $ \original -> do
    fresh <- must (freshScript original)
    let bytes = Native.encodeCbor original
        changed = Native.encodeCbor fresh
    assertBool "Nonminimal fixture already fresh" (bytes /= changed)
    Native.toJson fresh @?= Native.toJson original
    normalize 0 bytes >>= (@?= Right changed)
    Reencode.nativeScript original >>= (@?= Right fresh)
    sourceHash <- Native.hash original >>= must
    freshHash <- Native.hash fresh >>= must
    assertBool "Script hash ignored original representation" (sourceHash /= freshHash)
    -- Native oracle invalidates a deep clone; original native and Haskell
    -- snapshots retain their bytes even after the changed owner is released.
    copies <- replicateM 5 (normalize 0 bytes >>= must)
    performGC
    copies @?= replicate 5 changed
    Native.encodeCbor original @?= bytes
    Native.hash original >>= (@?= Right sourceHash)

scriptLists :: IO ()
scriptLists = do
  values <- scriptFixtures
  let supplied = values <> reverse values
      original = indefinite (foldMap Native.encodeCbor supplied)
  fresh <- traverse (must . freshScript) supplied
  let expected = indefinite (foldMap Native.encodeCbor fresh)
      definite = Cbor.encode (E.encodeListLen (fromIntegral (length fresh))) <> foldMap Native.encodeCbor fresh
  normalize 1 original >>= (@?= Right expected)
  encoded <- Encoded.fromBytes original >>= must
  result <- Reencode.nativeScripts encoded >>= must
  Encoded.toBytes result @?= expected
  assertBool "List envelope policy was erased" (expected /= definite)
  map Native.encodeCbor supplied @?= map nonminimalScript supplied

-- Native clearing resets node caches but keeps the child-list indefinite flag.
-- Semantic JSON reconstruction deliberately has a different representation
-- contract; these cases prevent claiming a general cache-clear equivalence.
scriptPolicies :: IO ()
scriptPolicies = do
  values <- scriptFixtures
  case values of
    leaf : _ -> do
      freshLeaf <- must (freshScript leaf)
      let children = indefinite (Native.encodeCbor leaf)
          freshChildren = indefinite (Native.encodeCbor freshLeaf)
          cases = [(B.pack [0x18, 1], B.pack [0x82, 1]), (B.pack [0x18, 2], B.pack [0x82, 2]), (B.pack [0x18, 3, 0x18, 1], B.pack [0x83, 3, 1])]
      forM_ cases $ \(sourcePrefix, freshPrefix) -> do
        let original = indefinite (sourcePrefix <> children)
            expected = freshPrefix <> freshChildren
        imported <- must (Native.decodeCbor original)
        fresh <- must (freshScript imported)
        changed <- normalize 0 original >>= must
        changed @?= expected
        public <- Reencode.nativeScript imported >>= must
        Native.encodeCbor public @?= expected
        assertBool "Construction JSON silently retained native indefinite policy" (changed /= Native.encodeCbor fresh)
        parsed <- must (Native.decodeCbor changed)
        Native.toJson parsed @?= Native.toJson fresh
        normalize 0 changed >>= (@?= Right expected)
        Native.encodeCbor imported @?= original
    [] -> assertFailure "Missing leaf fixture"

-- A nonminimal body with the same semantic zero fee as fresh assembly. Its
-- original bytes, not its decoded Fields record, define the signature message.
originalBodyBytes :: ByteString
originalBodyBytes = B.pack [0xa3, 0, 0x80, 1, 0x80, 2, 0x18, 0]

signedWitnesses :: ByteString -> IO Witnesses.EncodedWitnesses
signedWitnesses message = do
  (public, signature) <-
    SigningKey.withNormalKey
      (B.replicate 32 7)
      ( \key -> do
          public <- SigningKey.publicKey key
          signature <- SigningKey.sign key message
          pure ((,) <$> public <*> signature)
      )
      >>= must
  witnesses <- must (Witnesses.mkWitnesses [Witness.verificationWitness public signature] [] [] [] [])
  pure (Witnesses.fromWitnesses witnesses)

verifyWitnesses :: ByteString -> Witnesses.EncodedWitnesses -> IO ()
verifyWitnesses message witnesses = forM_ (Witnesses.verificationWitnesses (Witnesses.toWitnesses witnesses)) $ \witness ->
  PublicKey.verify (Witness.publicKey witness) message (Witness.signature witness) >>= (@?= Right True)

transactions :: IO ()
transactions = do
  body <- must (Body.decodeCbor originalBodyBytes)
  let unsigned = Tx.fromBody body
  identifier <- Tx.transactionId unsigned >>= must
  witnesses <- signedWitnesses (TxId.toBytes identifier)
  let signed = Tx.assemble body witnesses Nothing
      original = Tx.encodeCbor signed
  verifyWitnesses (TxId.toBytes identifier) witnesses
  changedBytes <- normalize 2 original >>= must
  public <- Reencode.transaction signed >>= must
  Tx.encodeCbor public @?= changedBytes
  changed <- must (Tx.decodeCbor changedBytes)
  changedId <- Tx.transactionId changed >>= must
  assertBool "Native body cache clearing retained nonminimal hash" (changedId /= identifier)
  Body.toBody (Tx.body changed) @?= Body.toBody body
  forM_ (Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses changed))) $ \witness ->
    PublicKey.verify (Witness.publicKey witness) (TxId.toBytes changedId) (Witness.signature witness) >>= (@?= Right False)
  freshBody <- must (Body.fromBody (Body.toBody body))
  -- The public setter treats representation-only replacement as a semantic
  -- no-op, keeping signed bytes; a real body edit drops outer signatures.
  Tx.encodeCbor (Tx.setBody freshBody signed) @?= original
  Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses (Tx.setFee 1 signed))) @?= []
  Tx.encodeCbor signed @?= original
  Tx.transactionId signed >>= (@?= Right identifier)

subTransactions :: IO ()
subTransactions = do
  let bodyBytes = B.pack [0xb8, 2, 0, 0x80, 1, 0x80]
  body <- must (SubBody.decodeCbor bodyBytes)
  identifier <- Sub.transactionId (Sub.fromBody body) >>= must
  witnesses <- signedWitnesses (TxId.toBytes identifier)
  let signed = Sub.assemble body witnesses Nothing
      original = Sub.encodeCbor signed
  changedBytes <- normalize 3 original >>= must
  public <- Reencode.subTransaction signed >>= must
  Sub.encodeCbor public @?= changedBytes
  changed <- must (Sub.decodeCbor changedBytes)
  changedId <- Sub.transactionId changed >>= must
  assertBool "Sub-body cache clearing retained nonminimal hash" (changedId /= identifier)
  SubBody.toBody (Sub.body changed) @?= SubBody.toBody body
  forM_ (Witnesses.verificationWitnesses (Witnesses.toWitnesses (Sub.witnesses changed))) $ \witness ->
    PublicKey.verify (Witness.publicKey witness) (TxId.toBytes changedId) (Witness.signature witness) >>= (@?= Right False)
  freshBody <- must (SubBody.fromBody (SubBody.toBody body))
  Sub.encodeCbor (Sub.setBody freshBody signed) @?= original
  modifiedBody <- must (SubBody.fromBody (SubBody.fromFields ((SubBody.fields (SubBody.toBody body)) {Fields.fieldDonation = Just 0})))
  Witnesses.verificationWitnesses (Witnesses.toWitnesses (Sub.witnesses (Sub.setBody modifiedBody signed))) @?= []
  -- Clearing an enclosing transaction does NOT recurse into signed intents.
  outerBody <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodySubTransactions = Just [signed]}))
  let outer = Tx.fromBody outerBody
  outerChanged <- normalize 2 (Tx.encodeCbor outer) >>= must >>= must . Tx.decodeCbor
  case fromMaybe [] (Body.bodySubTransactions (Body.toBody (Tx.body outerChanged))) of
    [intent] -> do
      SubBody.toCbor (Sub.body intent) @?= bodyBytes
      Sub.transactionId intent >>= (@?= Right identifier)
      Witnesses.verificationWitnesses (Witnesses.toWitnesses (Sub.witnesses intent)) @?= Witnesses.verificationWitnesses (Witnesses.toWitnesses witnesses)
      verifyWitnesses (TxId.toBytes identifier) (Sub.witnesses intent)
    _ -> assertFailure "Enclosing cache clearing lost its intent"
  Sub.encodeCbor signed @?= original

hashSnapshots :: IO ()
hashSnapshots = forM_ [1, 28, 32, 64, 256] $ \size -> do
  let bytes = B.pack (take size (cycle ([0 .. 255] :: [Word8])))
  hash <- must (Hash.fromBytes bytes)
  -- The source owner is released by C before serializing its deep clone.
  result <- normalize 4 (Hash.encodeCbor hash) >>= must
  parsed <- must (Hash.decodeCbor result)
  Hash.toBytes parsed @?= bytes
  performGC
  Hash.toBytes hash @?= bytes

failures :: IO ()
failures = do
  values <- scriptFixtures
  let script = case values of
        first : _ -> Native.encodeCbor first
        [] -> B.empty
      list = Cbor.encode (E.encodeListLen 1) <> script
      transaction = B.singleton 0x84 <> originalBodyBytes <> B.pack [0xa0, 0xf5, 0xf6]
      sub = B.singleton 0x83 <> B.pack [0xa2, 0, 0x80, 1, 0x80, 0xa0, 0xf6]
      hash = B.pack [0x41, 0xff]
  forM_ (zip [0 ..] [script, list, transaction, sub, hash]) $ \(kind, valid) ->
    forM_ [B.empty, valid <> B.singleton 0, B.take (B.length valid - 1) valid] (normalize kind >=> (assertBool "Malformed normalization input accepted" . isLeft))

-- Raw snapshots have deliberately more information than normalized Value.
-- Serialize native stored associations via getters rather than value_to_cbor,
-- whose map serialization can omit the empty groups under examination.
rawSnapshots :: IO ()
rawSnapshots = do
  first <- must (Policy.fromBytes (B.replicate 28 1))
  second <- must (Policy.fromBytes (B.replicate 28 2))
  empty <- must (Name.fromBytes B.empty)
  binary <- must (Name.fromBytes (B.pack [0, 255]))
  let groups = [(second, []), (first, [(binary, 7)]), (first, [(binary, 2), (empty, 0), (binary, -1)])]
  forM_ [negate (2 ^ (63 :: Int)), -1, 0, 2 ^ (63 :: Int) - 1] $ \amount -> do
    snapshot <- must (Raw.mkSnapshot amount groups)
    Raw.coin snapshot @?= amount
    Raw.assets snapshot @?= [(first, [(empty, 0), (binary, 2), (binary, -1)]), (second, [])]
    request <- must (rawBytes amount groups)
    expected <- must (rawBytes (Raw.coin snapshot) (Raw.assets snapshot))
    copy <- Runtime.withBytes request $ \input size -> Runtime.withOwnedBuffer "test.rawValue.clone" (cRawValueClone input size)
    copy @?= Right expected
    performGC
    Raw.assets snapshot @?= [(first, [(empty, 0), (binary, 2), (binary, -1)]), (second, [])]
  snapshot <- must (Raw.mkSnapshot 0 groups)
  let normalized = Raw.toValue snapshot
  Value.quantity (Asset.Native first binary) normalized @?= 1
  Value.quantity (Asset.Native first empty) normalized @?= 0
  roundTrip <- must (Raw.fromValue normalized)
  assertBool "Lossy normalization unexpectedly retained raw representation" (roundTrip /= snapshot)
  Raw.toValue roundTrip @?= normalized
  forM_ [negate (2 ^ (63 :: Int)) - 1, 2 ^ (63 :: Int)] $ \quantity -> do
    Raw.mkSnapshot quantity [] @?= Left (InvalidValueQuantity quantity)
    Raw.mkSnapshot 0 [(first, [(empty, quantity)])] @?= Left (InvalidValueQuantity quantity)
    Raw.fromValue (Value.lovelace quantity) @?= Left (InvalidValueQuantity quantity)
  emptySnapshot <- must (Raw.mkSnapshot 0 [])
  emptyBytes <- must (rawBytes (Raw.coin emptySnapshot) (Raw.assets emptySnapshot))
  Runtime.withBytes emptyBytes (\input size -> Runtime.withOwnedBuffer "test.rawValue.emptyClone" (cRawValueClone input size)) >>= (@?= Right emptyBytes)
  where
    rawBytes amount groups = do
      encoded <- traverse (\(policy, names) -> (Cbor.encode (E.encodeBytes (Policy.toBytes policy)) <>) <$> Collections.encodeAssetNamesCbor names) groups
      pure (Cbor.encode (E.encodeListLen 2 <> E.encodeInteger amount <> E.encodeMapLen (fromIntegral (length groups))) <> mconcat encoded)

bodySetMode :: IO ()
bodySetMode = do
  key <- must (Credential.keyHashFromBytes (B.replicate 28 6))
  base <- must (Body.fromBody ((Body.body [] [] 0) {Body.bodyFields = (Fields.fields [] []) {Fields.fieldGuards = Just [Credential.KeyCredential key]}}))
  forM_ [base, Body.withSetEncoding Body.Inputs TaggedSet base, Body.withSetEncoding Body.Inputs UntaggedSet base] $ \body -> do
    let expected = Body.setEncoding Body.Inputs body == Just TaggedSet
    Body.inputsAreTagged body @?= expected
    Runtime.withBytes (Body.toCbor body) $ \input size -> alloca $ \before -> alloca $ \after -> do
      cBodySetMode input size before after >>= (@?= 0)
      observed <- peek before
      dirty <- peek after
      observed @?= if expected then 1 else 0
      dirty @?= 1
  let mixed = Body.withSetEncoding Body.Inputs UntaggedSet base
  Body.setEncoding Body.Guards mixed @?= Just TaggedSet
  Body.inputsAreTagged mixed @?= False
  -- Once the body cache is discarded, the native input-set writer emits
  -- tag258 unconditionally. Observe the new bytes, keeping the source exact.
  reencoded <- Reencode.transaction (Tx.fromBody mixed) >>= must
  Body.inputsAreTagged (Tx.body reencoded) @?= True
  Body.inputsAreTagged mixed @?= False

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall safe "cometa_test_encoding_normalize"
  cNormalize :: CUInt -> Ptr Word8 -> CSize -> Ptr (Ptr Runtime.Buffer) -> IO NativeCode

foreign import ccall safe "cometa_test_raw_value_clone"
  cRawValueClone :: Ptr Word8 -> CSize -> Ptr (Ptr Runtime.Buffer) -> IO NativeCode

foreign import ccall safe "cometa_test_body_set_mode"
  cBodySetMode :: Ptr Word8 -> CSize -> Ptr CUInt -> Ptr CUInt -> IO NativeCode
