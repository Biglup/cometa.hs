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

-- | Independent byte/hash/signature fixtures and generated witness perturbations.
module IdentityReliability (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Ed25519.PublicKey as Public
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import qualified Cometa.Encoding.Hex as Hex
import Cometa.Error (Error)
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.SubTransaction.Body as SubBody
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Body as Body
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Witness as Witness
import qualified Cometa.Transaction.Witnesses as Witnesses
import qualified Cometa.TransactionId as TxId
import Control.Monad (forM_, zipWithM_, (>=>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Text (Text)
import Hedgehog (Property, evalIO, forAll, property)
import qualified Hedgehog.Gen as Gen
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Independent transaction identity"
    [ testCase "same semantic body has six independent byte-sensitive IDs and signatures" representationDomains,
      testProperty "framing, validity and witness order preserve the signed message" envelopeProperty,
      testCase "nested witnesses enter the outer commitment but never their own signed message" nestedCommitments
    ]

representationDomains :: IO ()
representationDomains = do
  canonical <- require (hex canonicalBodyHex) >>= require . Body.decodeCbor
  forM_ bodyFixtures $ \fixture -> do
    encoded <- require (hex (bodyHex fixture)) >>= require . Body.decodeCbor
    Body.toBody encoded @?= Body.toBody canonical
    let transaction = Tx.fromBody encoded
    checkIdentity fixture transaction
    expected <- require (hex (digestHex fixture))
    public <- require (Public.fromHex firstPublic)
    signature <- require (Signature.fromHex (firstSignature fixture))
    -- Neither raw body bytes nor complete envelopes are the Ed25519 message.
    Public.verify public (Body.toCbor encoded) signature >>= (@?= Right False)
    Public.verify public (Tx.encodeCbor transaction) signature >>= (@?= Right False)
    Public.verify public expected signature >>= (@?= Right True)
    forM_ bodyFixtures $ \other -> do
      otherDigest <- require (hex (digestHex other))
      Public.verify public otherDigest signature >>= (@?= Right (digestHex fixture == digestHex other))

-- Generated perturbations are deliberately outside the body. Expected IDs and
-- signatures below are independent literals, not a second call to Cometa hash.
envelopeProperty :: Property
envelopeProperty = property $ do
  fixture <- forAll (Gen.element bodyFixtures)
  reverseWitnesses <- forAll Gen.bool
  indefiniteWitnesses <- forAll Gen.bool
  frameStyle <- forAll (Gen.element [0 :: Int, 1, 2])
  valid <- forAll Gen.bool
  evalIO $ do
    encoded <- require (hex (bodyHex fixture))
    signatures <- mapM (require . Signature.fromHex) [firstSignature fixture, secondSignature fixture]
    publicKeys <- mapM (require . Public.fromHex) [firstPublic, secondPublic]
    let witnesses = zipWith Witness.verificationWitness publicKeys signatures
        ordered = if reverseWitnesses then reverse witnesses else witnesses
        witnessBytes =
          if indefiniteWitnesses
            then B.pack [0xbf, 0, 0xd9, 1, 2, 0x9f] <> foldMap Witness.encodeCbor ordered <> B.pack [0xff, 0xff]
            else B.pack [0xa1, 0, 0x82] <> foldMap Witness.encodeCbor ordered
        header = case frameStyle of
          0 -> B.singleton 0x84
          1 -> B.pack [0x98, 4]
          _ -> B.singleton 0x9f
        suffix = B.pack [if valid then 0xf5 else 0xf4, 0xf6] <> if frameStyle == 2 then B.singleton 0xff else B.empty
        bytes = header <> encoded <> witnessBytes <> suffix
    transaction <- require (Tx.decodeCbor bytes)
    Tx.encodeCbor transaction @?= bytes
    Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses transaction)) @?= ordered
    checkIdentity fixture transaction
    -- Existing independently valid partial signatures make signing an exact no-op,
    -- including nonminimal and indefinite containing frames and witness sets.
    forM_ [7, 8] $ \seed -> do
      signed <- Key.withNormalKey (B.replicate 32 seed) (`Signing.sign` transaction) >>= require
      Tx.encodeCbor signed @?= bytes
    Tx.encodeCbor transaction @?= bytes

checkIdentity :: BodyFixture -> Tx.Transaction -> IO ()
checkIdentity fixture transaction = do
  digest <- Tx.transactionId transaction >>= require
  Hex.encode (TxId.toBytes digest) @?= digestHex fixture
  zipWithM_ (checkWitness transaction) [7, 8] [firstSignature fixture, secondSignature fixture]
  where
    checkWitness original seed expected = do
      witness <- Key.withNormalKey (B.replicate 32 seed) (`Signing.verificationWitness` original) >>= require
      Hex.encode (Signature.toBytes (Witness.signature witness)) @?= expected
      Public.toHex (Witness.publicKey witness) @?= if seed == 7 then firstPublic else secondPublic

nestedCommitments :: IO ()
nestedCommitments = do
  subBody <- require (hex subBodyHex) >>= require . SubBody.decodeCbor
  expectedSubId <- require (hex subDigestHex)
  subWitnesses <- mapM (require . hex >=> require . Witness.decodeCbor) subWitnessHex
  expectedSubWitness <- require (hex firstSubWitnessHex) >>= require . Witness.decodeCbor
  -- These four native-backed outer IDs are checked against independent constants:
  -- no nested witnesses, one, two, and the same two in reverse order.
  forM_ nestedFixtures $ \(witnessHex, outerDigest) -> do
    encodedWitnesses <- require (hex witnessHex) >>= require . Witnesses.decodeCbor
    let nested = Sub.assemble subBody encodedWitnesses Nothing
        semanticOuter = (Body.body [] [] 10) {Body.bodySubTransactions = Just [nested]}
    enclosingBody <- require (Body.fromBody semanticOuter)
    let outer = Tx.fromBody enclosingBody
    Sub.transactionId nested >>= fmap TxId.toBytes . require >>= (@?= expectedSubId)
    Tx.transactionId outer >>= fmap (Hex.encode . TxId.toBytes) . require >>= (@?= outerDigest)
    forM_ subWitnesses $ \witness ->
      Public.verify (Witness.publicKey witness) expectedSubId (Witness.signature witness) >>= (@?= Right True)
    actualSubWitness <- Key.withNormalKey (B.replicate 32 7) (`Signing.subTransactionWitness` nested) >>= require
    Witness.encodeCbor actualSubWitness @?= Witness.encodeCbor expectedSubWitness
    signedOuter <- Key.withNormalKey (B.replicate 32 7) (`Signing.sign` outer) >>= require
    goldenOuterId <- require (hex outerDigest)
    forM_ (Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses signedOuter))) $ \witness -> do
      Public.verify (Witness.publicKey witness) goldenOuterId (Witness.signature witness) >>= (@?= Right True)
      Public.verify (Witness.publicKey witness) expectedSubId (Witness.signature witness) >>= (@?= Right False)
    Public.verify (Witness.publicKey expectedSubWitness) goldenOuterId (Witness.signature expectedSubWitness) >>= (@?= Right False)
    -- A nested witness-only replacement is a real OUTER body edit. It drops only
    -- the outer signature; the replacement's independently signed body survives.
    let replacement = Sub.setWitnesses (Witnesses.fromWitnesses Witnesses.empty) nested
    changedBody <- require (Body.fromBody semanticOuter {Body.bodySubTransactions = Just [replacement]})
    let changedOuter = Tx.setBody changedBody signedOuter
    if witnessHex == "a0"
      then Tx.encodeCbor changedOuter @?= Tx.encodeCbor signedOuter
      else Witnesses.verificationWitnesses (Witnesses.toWitnesses (Tx.witnesses changedOuter)) @?= []
    Body.toCbor (Tx.body signedOuter) @?= Body.toCbor enclosingBody
    removedId <- Tx.transactionId changedOuter >>= require
    Hex.encode (TxId.toBytes removedId) @?= emptyNestedDigest
    if witnessHex == "a0"
      then pure ()
      else assertBool "removing nested witnesses did not change the outer commitment" (Hex.encode (TxId.toBytes removedId) /= outerDigest)
    Sub.body replacement @?= Sub.body nested
    Sub.transactionId replacement >>= fmap TxId.toBytes . require >>= (@?= expectedSubId)

hex :: Text -> Either Error ByteString
hex = Hex.decode

require :: (Show failure) => Either failure value -> IO value
require = either (\failure -> assertFailure (show failure) >> fail "identity fixture") pure

-- Independently generated with Python hashlib.blake2b(digest_size=32) and
-- cryptography48/OpenSSL4 Ed25519, synthetic PUBLIC test seeds32*07 and32*08.
-- These are original structural fixtures, not claimed ledger-valid transactions.
-- Law provenance: cardano-api c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a,
-- Cardano/Api/Tx/Internal/Sign.hs makeShelleyKeyWitness', hashTxBody (Apache2).
data BodyFixture = BodyFixture
  { bodyHex :: Text,
    digestHex :: Text,
    firstSignature :: Text,
    secondSignature :: Text
  }
  deriving (Show)

bodyFixtures :: [BodyFixture]
bodyFixtures =
  [ BodyFixture "a300818258200000000000000000000000000000000000000000000000000000000000000000000180020a" "892b5222180f305c1014d89c71f08222934fbfbb5811b0b7e70e23fe35a8c508" "3a8641a2ab663fef52344744c9816f65d016490ac666a46f205c140224b646c945f6caf9de51d2b5f45d463a841b56b0fa4593cefcdaad92722612519028ef0e" "a09077a52f3968494fa45cdf6e338f2710ded73ae17c492013bfc4749b3d235ddf34f56be4bafe281a0fdc3ac4fe2d85df1c1888599ec82c51b4d9e463857a0f",
    BodyFixture "a30081825820000000000000000000000000000000000000000000000000000000000000000000018002180a" "cd1eec9efaf5fe760d11e84ae6aff2ebd4febd389e22e683d24cf21b504b8ffa" "27d1a0574c4d8995e70b765fd316888c9693bef0c425aa54e53862d95852fd132f1bddcbdd63099d5f7cab81a00127898804f49f703c874e56dc01e42b56cc0f" "5d54058bd627a51162cc34df2aba9f33fb243295c7db93c335df90aa65ee50fa1952fd84563b7e2d01ad92b9097320f0c9c763e5af056d73ecd930c064d5eb0a",
    BodyFixture "a3008182582000000000000000000000000000000000000000000000000000000000000000000001800219000a" "5b096df8268eef6b34b513c44b3eee248c78bbcd08fde42d477acdda281f6f88" "1b697cbe33ba28fe9b225aa8dc839ddac5641b5979b4ae3d3db50c45f154b5169e00d64c6d57c92f64d3545f1566251d48af09085a59b5fea9e17aa963b55007" "11bddb083ad9f82adca19d2f4fd2c0582f01a66ca841e7c1afe6915d7ce6d0f16adba9d1387f68594cb71a73dd9b493a003a1fa5ee1ee19750ca463ebb154f01",
    BodyFixture "a300818258200000000000000000000000000000000000000000000000000000000000000000000180021b000000000000000a" "393de005eb8ff7e9f61c7a529bc84102aeaf2649eee2de828f7e0216139ef21c" "9e5010e0768cc319bf5c89487760bd729cc58939113879110a276008954129ffdc0295d7ddbfc53aac0143fbaf5a15df2c7dcc794ddc88988a2a09e061288402" "4342b685a337fba8a1ed5f7e1a47429558be9f99189ecbc09acf30c13a4b76a786ca683c3c89a8a23af9bb99296d1c56b2381e30a3d9de2e8bfec90d37bfe50d",
    BodyFixture "a3020a01800081825820000000000000000000000000000000000000000000000000000000000000000000" "3fa334549d9a1faf89ecdc39f7f79ca96d8d297d5ea432b586fb153cd4821f2e" "2e130759c748a1fcd9447fa690013f506c09e00aec852ae3e4436ff8a0d3f6fc84b483dea77303e43d42a144eb3d76a2ad5922a3bff75517e422441b1d210700" "0ead872221cb0335b19bdd57310321b6a7aa67e210f1c8a31510aefdc6d1239ddf9296392acbc0b01dd125d5336b6a9512acbea3b74b43d3df45a7b9c3cc6008",
    BodyFixture "a300d90102818258200000000000000000000000000000000000000000000000000000000000000000000180020a" "5dcf62a26468a0c62aedb191b1436592caeadd1296f0e002d85914fa3a4022a5" "cbc9d1658d6583f7b9a0d028b88b802c06c837990f1759f4a6f09770d472919a5ace88a2928f769b8e461c8a6bfff02265f4ae2f55cb2cdd702fdb56df99e30b" "f2f91bbc618b14b74ce2d7970944c722e3f6ad27e86f54711f42bcb471c7d2151cbd971295e0864713c84443a8b35d147e29dfee772d0ae39895e60895a08802"
  ]

canonicalBodyHex :: Text
canonicalBodyHex = "a300818258200000000000000000000000000000000000000000000000000000000000000000000180020a"

firstPublic :: Text
firstPublic = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"

secondPublic :: Text
secondPublic = "1398f62c6d1a457c51ba6a4b5f3dbd2f69fca93216218dc8997e416bd17d93ca"

subBodyHex :: Text
subBodyHex = "a200818258200000000000000000000000000000000000000000000000000000000000000000000180"

subDigestHex :: Text
subDigestHex = "fcd7d304d7fadb2f6813e5401cf4e610fde1c18836f05d14c05b931f2c55672b"

firstSubWitnessHex :: Text
firstSubWitnessHex = "825820ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c5840a7b05e6901f110f045f1ffa076b0849e91373b1325dee814a35e7485d83c960b0cd24c699ed1525c6b26b21d9ef1149462686c6747b847cf3de3b40696529e0b"

subWitnessHex :: [Text]
subWitnessHex = ["825820ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c5840a7b05e6901f110f045f1ffa076b0849e91373b1325dee814a35e7485d83c960b0cd24c699ed1525c6b26b21d9ef1149462686c6747b847cf3de3b40696529e0b", "8258201398f62c6d1a457c51ba6a4b5f3dbd2f69fca93216218dc8997e416bd17d93ca584091997dc4eb6b30716c2172aee040a0a25aa885b7068801bd8c0b4a240d699577f08e741fbc81af8d1172392a709a99882a1c4c68f63a35144a44ff4175007a0d"]

nestedFixtures :: [(Text, Text)]
nestedFixtures =
  [ ("a0", "6380afc9a4d13fb5bacab03c76ab0543478c90d622d8278b269d71f8aaef9004"),
    ("a10081825820ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c5840a7b05e6901f110f045f1ffa076b0849e91373b1325dee814a35e7485d83c960b0cd24c699ed1525c6b26b21d9ef1149462686c6747b847cf3de3b40696529e0b", "1f393c5fe471664d9e3a6dc384b08266fa88fc6f598f419ec8ac2520d3f58f7a"),
    ("a10082825820ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c5840a7b05e6901f110f045f1ffa076b0849e91373b1325dee814a35e7485d83c960b0cd24c699ed1525c6b26b21d9ef1149462686c6747b847cf3de3b40696529e0b8258201398f62c6d1a457c51ba6a4b5f3dbd2f69fca93216218dc8997e416bd17d93ca584091997dc4eb6b30716c2172aee040a0a25aa885b7068801bd8c0b4a240d699577f08e741fbc81af8d1172392a709a99882a1c4c68f63a35144a44ff4175007a0d", "f08f018f4f36ae1c7cebf80be1b86186b91dc7de736640d592e1ba816c6c5006"),
    ("a100828258201398f62c6d1a457c51ba6a4b5f3dbd2f69fca93216218dc8997e416bd17d93ca584091997dc4eb6b30716c2172aee040a0a25aa885b7068801bd8c0b4a240d699577f08e741fbc81af8d1172392a709a99882a1c4c68f63a35144a44ff4175007a0d825820ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c5840a7b05e6901f110f045f1ffa076b0849e91373b1325dee814a35e7485d83c960b0cd24c699ed1525c6b26b21d9ef1149462686c6747b847cf3de3b40696529e0b", "a4ff1bb5062b3f34f399dcd3ab9c3af57439d9f0f8bfa7270edac6388e1dad49")
  ]

emptyNestedDigest :: Text
emptyNestedDigest = "6380afc9a4d13fb5bacab03c76ab0543478c90d622d8278b269d71f8aaef9004"
