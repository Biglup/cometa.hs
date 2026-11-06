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

-- | Typed witness workflows, exact identity, native reconstruction and failures.
module TransactionWitnesses (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as Key
import qualified Cometa.Crypto.Ed25519.Signature as Sig
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as Data
import Cometa.Protocol.ExUnits (ExUnits (..))
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as Native
import qualified Cometa.Script.Plutus as Plutus
import qualified Cometa.Transaction.AuxiliaryData as Aux
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
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
    "Transaction witnesses"
    [ testCase "typed witnesses and every redeemer purpose reconstruct natively" checkNative,
      testCase "pinned key/bootstrap corpus is assembled from typed public values" checkGolden,
      testCase "auxiliary corpus retains all historical forms and V4" checkAuxiliaryGolden,
      testCase "nested exact bytes survive adding/removing signatures" checkExact,
      testCase "merge identity, idempotence, disjoint associativity and conflicts" checkMerge,
      testCase "full exact auxiliary CBOR determines its hash" checkHash,
      testCase "invalid schemas and partial native failures clean up" checkInvalid,
      testCase "repeated reconstruction balances retained getters" (replicateM_ 100 checkNative),
      testProperty "generated typed witnesses reconstruct and round trip" propRoundTrip
    ]

sample :: Word8 -> Word64 -> Either Error (Witness.VerificationWitness, Witness.BootstrapWitness, [Redeemer.Redeemer], Witnesses.Witnesses, Aux.AuxiliaryData)
sample seed amount = do
  key <- Key.fromBytes (B.replicate 32 seed)
  signature <- Sig.fromBytes (B.replicate 64 seed)
  boot <- Witness.mkBootstrapWitness key signature (B.replicate 32 (seed + 1)) "\160"
  scripts <- traverse (`Plutus.fromBytes` "script") [minBound .. maxBound]
  let witness = Witness.verificationWitness key signature
      argument = Data.fromData (Data.Integer (toInteger amount))
      rs = [Redeemer.Redeemer purpose (fromIntegral (amount `mod` 4294967296)) argument (ExUnits amount amount) | purpose <- [minBound .. maxBound]]
      natives = [Native.allOf []]
  ws <- Witnesses.mkWitnesses [witness] [boot] (map Script.Native natives ++ map Script.Plutus scripts) [argument, argument] rs
  pure (witness, boot, rs, ws, Aux.auxiliaryData Nothing (Just natives) scripts)

checkNative :: IO ()
checkNative = do
  (key, boot, rs, ws, aux) <- require (sample 7 maxBound)
  agree 0 (Witness.encodeCbor key)
  agree 1 (Witness.encodeBootstrapCbor boot)
  forM_ rs (agree 2 . Redeemer.encodeCbor)
  agree 3 (Witnesses.encodeCbor ws)
  agree 4 (Aux.encodeCbor aux)

checkGolden :: IO ()
checkGolden = do
  key <- require (hexBytes keyHex >>= Key.fromBytes)
  signature <- require (hexBytes signatureHex >>= Sig.fromBytes)
  boot <- require (Witness.mkBootstrapWitness key signature (B.replicate 32 0) "\160")
  expectedKey <- require (hexBytes keyGolden)
  expectedBoot <- require (hexBytes bootstrapGolden)
  Witness.encodeCbor (Witness.verificationWitness key signature) @?= expectedKey
  Witness.encodeBootstrapCbor boot @?= expectedBoot
  agree 0 expectedKey
  agree 1 expectedBoot

checkAuxiliaryGolden :: IO ()
checkAuxiliaryGolden = forM_ auxiliaryGoldens $ \golden -> do
  bytes <- require (hexBytes golden)
  decoded <- require (Aux.decodeCbor bytes)
  Aux.toCbor decoded @?= bytes
  -- Reassemble a fresh tagged envelope from public typed fields.
  let value = Aux.toAuxiliaryData decoded
      scripts = concat [fromMaybe [] (Aux.plutusV1Scripts value), fromMaybe [] (Aux.plutusV2Scripts value), fromMaybe [] (Aux.plutusV3Scripts value), fromMaybe [] (Aux.plutusV4Scripts value)]
      fresh = Aux.auxiliaryData (Aux.metadata value) (Aux.nativeScripts value) scripts
  agree 4 (Aux.encodeCbor fresh)

checkExact :: IO ()
checkExact = do
  -- Indefinite witness map/set and nonminimal datum integer. The whole datum
  -- field must survive a signature-only edit byte for byte.
  bytes <- require (hexBytes "bf04d901029f1800ffff")
  original <- require (Witnesses.decodeCbor bytes)
  (key, _, _, _, _) <- require (sample 1 0)
  added <- require (Witnesses.addVerificationWitness key original)
  let removed = Witnesses.removeKeyWitnesses added
  map Data.toData (Witnesses.datums (Witnesses.toWitnesses removed)) @?= [Data.Integer 0]
  expected <- require (hexBytes "a104d901029f1800ff")
  Witnesses.toCbor removed @?= expected
  Witnesses.toCbor (Witnesses.removeKeyWitnesses original) @?= bytes
  Witnesses.toCbor <$> Witnesses.mergeEncoded original (Witnesses.fromWitnesses Witnesses.empty) @?= Right bytes

checkMerge :: IO ()
checkMerge = do
  (a, _, _, _, _) <- require (sample 1 0)
  (b, _, _, _, _) <- require (sample 2 0)
  (c, _, _, _, _) <- require (sample 3 0)
  x <- require (Witnesses.mkWitnesses [a] [] [] [] [])
  y <- require (Witnesses.mkWitnesses [b] [] [] [] [])
  z <- require (Witnesses.mkWitnesses [c] [] [] [] [])
  Witnesses.merge x Witnesses.empty @?= Right x
  Witnesses.merge x x @?= Right x
  repeated <- require (Witnesses.mkWitnesses [a, a] [] [] [] [])
  repeatedDecoded <- require (Witnesses.decodeCbor (Witnesses.encodeCbor repeated))
  Witnesses.verificationWitnesses (Witnesses.toWitnesses repeatedDecoded) @?= [a, a]
  Witnesses.merge repeated x @?= Right repeated
  -- The same validated key/signature in a different array/set/map framing is
  -- still an identical key witness; merging must retain the original envelope.
  let noncanonicalBytes = B.pack [0xbf, 0x18, 0, 0x9f, 0x9f] <> B.drop 1 (Witness.encodeCbor a) <> B.pack [0xff, 0xff, 0xff]
  noncanonical <- require (Witnesses.decodeCbor noncanonicalBytes)
  same <- require (Witnesses.mergeEncoded noncanonical (Witnesses.fromWitnesses x))
  Witnesses.toCbor same @?= noncanonicalBytes
  (Witnesses.merge x y >>= (`Witnesses.merge` z)) @?= (Witnesses.merge y z >>= Witnesses.merge x)
  otherSig <- require (Sig.fromBytes (B.replicate 64 99))
  conflict <- require (Witnesses.mkWitnesses [Witness.verificationWitness (Witness.publicKey a) otherSig] [] [] [] [])
  assertBool "conflicting key signatures fail" (isLeft (Witnesses.merge x conflict))
  let argument = Data.fromData (Data.Integer 0)
      first = Redeemer.Redeemer Redeemer.Spending 0 argument (ExUnits 1 2)
      second = first {Redeemer.executionUnits = ExUnits 3 4}
  left <- require (Witnesses.mkWitnesses [] [] [] [] [first])
  right <- require (Witnesses.mkWitnesses [] [] [] [] [second])
  assertBool "conflicting redeemer budgets fail" (isLeft (Witnesses.merge left right))

checkHash :: IO ()
checkHash = do
  a <- require (hexBytes "d90103a0" >>= Aux.decodeCbor)
  b <- require (hexBytes "d90103bfFF" >>= Aux.decodeCbor)
  ah <- Aux.hash a >>= require
  bh <- Aux.hash b >>= require
  expected <- Blake2b.compute 32 (Aux.toCbor a) >>= require
  Aux.hashBytes ah @?= Blake2b.toBytes expected
  golden <- require (hexBytes "bdaa99eb158414dea0a91d6c727e2268574b23efe6e08ab3b841abe8059a030c")
  Aux.hashBytes ah @?= golden
  assertBool "exact envelope changes hash" (ah /= bh)
  meta <- require (Metadata.mkMetadata [])
  encodedMeta <- require (Metadata.decodeCbor (Metadata.encodeCbor meta))
  let withMeta = Aux.fromAuxiliaryData (Aux.auxiliaryData (Just encodedMeta) Nothing [])
  mh <- Aux.hash withMeta >>= require
  assertBool "present empty metadata changes full auxiliary hash" (ah /= mh)
  let withScript = Aux.fromAuxiliaryData (Aux.auxiliaryData Nothing (Just [Native.allOf []]) [])
  scriptHash <- Aux.hash withScript >>= require
  assertBool "auxiliary scripts affect the full hash" (ah /= scriptHash)

checkInvalid :: IO ()
checkInvalid = do
  forM_ ["a10080ff", "a200800080", "a10980", "a105a1810000820000", "a105a182001b00000001000000008200820000", "a105a18207008200820000", "a105a282000082008200008200008200820000"] $ \hex -> do
    bytes <- require (hexBytes hex)
    assertBool "invalid witness CBOR rejected" (isLeft (Witnesses.decodeCbor bytes))
  forM_ ["d90103a201800180", "d90103a10680", "d90103a1018180", "83a08080", "d90103a0ff"] $ \hex -> do
    bytes <- require (hexBytes hex)
    assertBool "invalid auxiliary CBOR rejected" (isLeft (Aux.decodeCbor bytes))
  (key, _, rs, _, _) <- require (sample 0 0)
  assertBool "chain length rejected" (isLeft (Witness.mkBootstrapWitness (Witness.publicKey key) (Witness.signature key) B.empty B.empty))
  assertBool "duplicate redeemer identifiers rejected" (isLeft (Redeemer.mkCollection (rs ++ rs)))
  forM_ [0 .. 4] $ \kind -> do
    result <- nativeAgree kind (B.pack [0x81, 0])
    result @?= False

propRoundTrip :: Property
propRoundTrip = property $ do
  seed <- forAll (Gen.word8 Range.constantBounded)
  amount <- forAll (Gen.word64 Range.constantBounded)
  (_, _, _, value, auxiliary) <- evalEither (sample seed amount)
  parsed <- evalEither (Witnesses.decodeCbor (Witnesses.encodeCbor value))
  Witnesses.toWitnesses parsed === value
  native <- evalIO (nativeAgree 3 (Witnesses.encodeCbor value))
  native === True
  auxNative <- evalIO (nativeAgree 4 (Aux.encodeCbor auxiliary))
  auxNative === True

hexBytes :: Text -> Either Error ByteString
hexBytes = maybe (Left InvalidHex) Right . Hex.decodeHex

require :: Either Error a -> IO a
require value = case value of
  Left failure -> assertFailure (show failure) >> fail "unreachable"
  Right result -> pure result

agree :: CUInt -> ByteString -> IO ()
agree kind bytes = nativeAgree kind bytes >>= assertBool "fresh native reconstruction agrees"

nativeAgree :: CUInt -> ByteString -> IO Bool
nativeAgree kind bytes = B.useAsCStringLen bytes $ \(input, size) -> (/= 0) <$> cAgree kind (castPtr input) (fromIntegral size)

foreign import ccall unsafe "cometa_test_transaction_witnesses_agree"
  cAgree :: CUInt -> Ptr Word8 -> CSize -> IO CInt

-- Imported Apache-2.0 fixtures: cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/witness_set/{vkey_witness,bootstrap_witness}.cpp and
-- lib/tests/auxiliary_data/auxiliary_data.cpp constants named below.

keyHex :: Text
keyHex = "3D4017C3E843895A92B70AA74D1B7EBC9C982CCF2EC4968CC0CD55F12AF4660C"

signatureHex :: Text
signatureHex = "6291D657DEEC24024827E69C3ABE01A30CE548A284743A445E3680D7DB5AC3AC18FF9B538D16F290AE67F760984DC6594A7C15E9716ED28DC027BECEEA1EC40A"

keyGolden :: Text
keyGolden = "8258203d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c58406291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"

bootstrapGolden :: Text
bootstrapGolden = "8458203d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c58406291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a5820000000000000000000000000000000000000000000000000000000000000000041a0"

auxiliaryGoldens :: [Text]
auxiliaryGoldens =
  [ "d90103a500a11902d5a4187b1904d2636b65796576616c7565646b65793246000102030405a1190237656569676874a119029a6463616b6501848204038205098202818200581c3542acb3a64d80c29302260d62c3b87a742ad14abf855ebc6733081e830300818200581cb5ae663aaea8e500157bdf4baafd6f5ba0ce5759f7cd4101fc132f5402844746010000220010474601000022001147460100002200124746010000220013038447460100002200104746010000220011474601000022001247460100002200130483474601000022001047460100002200114746010000220012",
    "d90103a600a11902d5a4187b1904d2636b65796576616c7565646b65793246000102030405a1190237656569676874a119029a6463616b6501848204038205098202818200581c3542acb3a64d80c29302260d62c3b87a742ad14abf855ebc6733081e830300818200581cb5ae663aaea8e500157bdf4baafd6f5ba0ce5759f7cd4101fc132f54028447460100002200104746010000220011474601000022001247460100002200130384474601000022001047460100002200114746010000220012474601000022001304834746010000220010474601000022001147460100002200120583474601000022001047460100002200114746010000220012",
    "82a11902d5a4187b1904d2636b65796576616c7565646b65793246000102030405a1190237656569676874a119029a6463616b65828202818200581c3542acb3a64d80c29302260d62c3b87a742ad14abf855ebc6733081e830300818200581cb5ae663aaea8e500157bdf4baafd6f5ba0ce5759f7cd4101fc132f54",
    "a11902d5a4187b1904d2636b65796576616c7565646b65793246000102030405a1190237656569676874a119029a6463616b65"
  ]
