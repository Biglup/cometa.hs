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

-- | Apache-2.0 native vectors from cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1,
-- lib/tests/message_signing/cip8.cpp. COSE fields and Sig_structure are also
-- decoded/reconstructed through public CBOR values and cryptographically checked.
module Cip8 (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Cometa.Crypto.Ed25519.PublicKey as Public
import qualified Cometa.Crypto.Ed25519.Signature as Signature
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import qualified Cometa.Encoding.Cbor as Cbor
import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import qualified Cometa.Message.Cip8 as Cip8
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, replicateM_, (>=>))
import qualified Data.ByteString as B
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "CIP8"
    [ testCase "address and key-hash native vectors and independent verification" vectors,
      testCase "binary payload, direct signing and empty AAD" binary,
      testCase "normal seed keys sign without checking address control" normalKey,
      testCase "bindings do not validate control of the signing key" mismatched,
      testCase "empty payload and closed key fail without poisoning a live key" failures,
      testCase "owned results, repeated calls and independent concurrent scopes" lifetime
    ]

privateKey :: Text
privateKey = "d06d3744d9089b21b1fbb736a45d359ed5d5b4028800e70aa1a2968183cb68528ef06f1c2b289a85e09738d528869dd1f69f436ada4b471b12e950a2b9e780b6"

address :: IO Address.Address
address = require (Address.fromText "addr_test1qqja52pwpq7v7amg34r6x9dpp5le04n6cmqf2zpnurt2lm48wgx7j5cur9w0zxv7ky333eef3akg092hhcmp3teeth3qktnslv")

hashBinding :: B.ByteString -> IO Cip8.Binding
hashBinding bytes = Cip8.keyHashBinding <$> require (Credential.keyHashFromBytes bytes :: Either Error (Credential.KeyHash Credential.DRep))

withKey :: (Key.SigningKey -> IO ()) -> IO ()
withKey action = Key.withExtendedKeyHex privateKey (\key -> action key >> pure (Right ())) >>= require

vectors :: IO ()
vectors = withKey $ \key -> do
  addr <- address
  hash <- Cbor.fromHex "581c25da282e083ccf77688d47a315a10d3f97d67ac6c0950833e0d6afee" >>= require >>= Cbor.decodeByteString >>= require
  binding <- hashBinding hash
  forM_ [(Cip8.addressBinding addr, Address.toBytes addr, addressSign, addressKey), (binding, hash, hashSign, hashKey)] $ \(bound, bytes, expectedSign, expectedKey) -> do
    signed <- Cip8.sign key bound (B.pack [0xab, 0xc1, 0x23]) >>= require
    Cbor.fromBytes (Cip8.coseSign1 signed) >>= require >>= (\cbor -> Cbor.toHex cbor @?= expectedSign)
    Cbor.fromBytes (Cip8.coseKey signed) >>= require >>= (\cbor -> Cbor.toHex cbor @?= expectedKey)
    verify key bytes (B.pack [0xab, 0xc1, 0x23]) signed

binary :: IO ()
binary = withKey $ \key -> do
  addr <- address
  let payload = B.pack [0, 255, 128, 0, 1, 0]
  signed <- Cip8.sign key (Cip8.addressBinding addr) payload >>= require
  verify key (Address.toBytes addr) payload signed

normalKey :: IO ()
normalKey = do
  addr <- address
  Key.withNormalKey
    (B.replicate 32 7)
    ( \key -> do
        public <- Key.publicKey key >>= require
        digest <- Public.hash public >>= require
        assertBool "address payment credential must differ from signing key" (Blake2b.toBytes digest /= B.take 28 (B.drop 1 (Address.toBytes addr)))
        signed <- Cip8.sign key (Cip8.addressBinding addr) "normal key" >>= require
        verify key (Address.toBytes addr) "normal key" signed
        pure (Right ())
    )
    >>= require

mismatched :: IO ()
mismatched = withKey $ \key -> do
  let bytes = B.replicate 28 0
  binding <- hashBinding bytes
  signed <- Cip8.sign key binding "mismatched binding" >>= require
  verify key bytes "mismatched binding" signed

failures :: IO ()
failures = do
  addr <- address
  let binding = Cip8.addressBinding addr
  withKey $ \key -> do
    empty <- Cip8.sign key binding B.empty
    case empty of
      Left (NativeError "cip8.sign" Code.InvalidArgument _) -> pure ()
      _ -> assertFailure "empty payload should fail with InvalidArgument"
    lazy <- try (Cip8.sign key binding (error "lazy payload")) :: IO (Either SomeException (Either Error Cip8.SignedMessage))
    assertBool "lazy payload must throw" (either (const True) (const False) lazy)
    _ <- Cip8.sign key binding "usable afterward" >>= require
    pure ()
  closed <- Key.withExtendedKeyHex privateKey (pure . Right) >>= require
  Cip8.sign closed binding "closed" >>= (@?= Left SigningKeyClosed)

lifetime :: IO ()
lifetime = do
  addr <- address
  let binding = Cip8.addressBinding addr
      operation = Key.withExtendedKeyHex privateKey $ \key -> Cip8.sign key binding "retained"
  retained <- operation >>= require
  replicateM_ 30 (operation >>= require >>= (@?= retained))
  withKey $ \key -> verify key (Address.toBytes addr) "retained" retained
  completions <- mapM (const newEmptyMVar) [1 :: Int .. 8]
  forM_ completions $ \done -> do
    _ <- forkFinally operation (putMVar done)
    pure ()
  forM_ completions $ \done -> do
    result <- takeMVar done
    either (assertFailure . show) (require >=> (@?= retained)) result

verify :: Key.SigningKey -> B.ByteString -> B.ByteString -> Cip8.SignedMessage -> IO ()
verify key binding payload signed = do
  signFields <- Cbor.fromBytes (Cip8.coseSign1 signed) >>= require >>= Cbor.decodeArray >>= require
  case signFields of
    [protected, unprotected, encodedPayload, encodedSignature] -> do
      Cbor.decodeByteString encodedPayload >>= require >>= (@?= payload)
      protectedBytes <- Cbor.decodeByteString protected >>= require
      headers <- Cbor.fromBytes protectedBytes >>= require >>= Cbor.decodeMap >>= require
      algorithm <- intField 1 headers
      Cbor.decodeInteger algorithm >>= require >>= (@?= (-8))
      bound <- textField "address" headers
      Cbor.decodeByteString bound >>= require >>= (@?= binding)
      annotations <- Cbor.decodeMap unprotected >>= require
      hashed <- textField "hashed" annotations
      Cbor.decodeBool hashed >>= require >>= (@?= False)
      keyFields <- Cbor.fromBytes (Cip8.coseKey signed) >>= require >>= Cbor.decodeMap >>= require
      forM_ [(1, 1), (3, -8), (-1, 6)] $ \(label, expected) -> intField label keyFields >>= Cbor.decodeInteger >>= require >>= (@?= expected)
      publicBytes <- intField (-2) keyFields >>= Cbor.decodeByteString >>= require
      public <- Key.publicKey key >>= require
      publicBytes @?= Public.toBytes public
      intField 2 keyFields >>= Cbor.decodeByteString >>= require >>= (@?= binding)
      signature <- Cbor.decodeByteString encodedSignature >>= require >>= (require . Signature.fromBytes)
      context <- Cbor.encodeText "Signature1" >>= require
      emptyAad <- Cbor.encodeByteString B.empty >>= require
      preimage <- Cbor.encodeArray [context, protected, emptyAad, encodedPayload] >>= require
      Public.verify public (Cbor.toBytes preimage) signature >>= (@?= Right True)
      wrongAad <- Cbor.encodeByteString "different AAD" >>= require
      wrongStructure <- Cbor.encodeArray [context, protected, wrongAad, encodedPayload] >>= require
      Public.verify public (Cbor.toBytes wrongStructure) signature >>= (@?= Right False)
      Public.verify public payload signature >>= (@?= Right False)
    _ -> assertFailure "COSE_Sign1 must contain exactly four fields"

intField :: Integer -> [(Cbor.Cbor, Cbor.Cbor)] -> IO Cbor.Cbor
intField label fields = Cbor.encodeInteger label >>= require >>= (\encoded -> maybe (assertFailure "missing integer header" >> fail "missing") pure (lookup encoded fields))

textField :: Text -> [(Cbor.Cbor, Cbor.Cbor)] -> IO Cbor.Cbor
textField label fields = Cbor.encodeText label >>= require >>= (\encoded -> maybe (assertFailure "missing text header" >> fail "missing") pure (lookup encoded fields))

require :: (Show failure) => Either failure value -> IO value
require = either (\failure -> assertFailure (show failure) >> fail "unexpected failure") pure

addressSign :: Text
addressSign = "845882a301270458390025da282e083ccf77688d47a315a10d3f97d67ac6c0950833e0d6afeea7720de9531c195cf1199eb12318e7298f6c879557be3618af395de2676164647265737358390025da282e083ccf77688d47a315a10d3f97d67ac6c0950833e0d6afeea7720de9531c195cf1199eb12318e7298f6c879557be3618af395de2a166686173686564f443abc1235840cf4f8356899ef40f4c21869b50a3d5dc95414a8d3c1aae088b7518a65069cdf841331877c16f11f6a88bbfe402e8fbb338a5646ff2d931d5e955c6717cf1c404"

addressKey :: Text
addressKey = "a501010258390025da282e083ccf77688d47a315a10d3f97d67ac6c0950833e0d6afeea7720de9531c195cf1199eb12318e7298f6c879557be3618af395de20327200621582088cb67866b59520bffcfe9c421ef5d9e0db88815637796f597d3305126c8c78c"

hashSign :: Text
hashSign = "845829a201276761646472657373581c25da282e083ccf77688d47a315a10d3f97d67ac6c0950833e0d6afeea166686173686564f443abc1235840a079c58895a1da28dc4c696321b0d1649590acc9813a43aa0a0e172705326665aec54fbc0ce6dc2a6c1972f25d1c8ee8f36b169709afdebf057e929afc900306"

hashKey :: Text
hashKey = "a5010102581c25da282e083ccf77688d47a315a10d3f97d67ac6c0950833e0d6afee0327200621582088cb67866b59520bffcfe9c421ef5d9e0db88815637796f597d3305126c8c78c"
