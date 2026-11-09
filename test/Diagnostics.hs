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

-- | Typed diagnostic labels checked against native enum labels, independently
-- extracting the discriminant from the existing public CBOR encodings.
module Diagnostics (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Certificates
import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Read as Read
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Credential as Credential
import qualified Cometa.Diagnostics as Display
import qualified Cometa.Governance.Voting as Voting
import qualified Cometa.NetworkMagic as Network
import qualified Cometa.Script.Native as Native
import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CUInt (..))
import qualified Scripts
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- FOREIGN IMPORTS ------------------------------------------------------------

-- | Borrow a static ASCII label; no owner is created or released.
foreign import ccall unsafe "cometa_test_diagnostic_label"
  nativeLabel :: CUInt -> Word32 -> IO CString

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Diagnostic labels"
    [ testCase "network magics and unknown names match native values" checkNetworks,
      testCase "all certificate kinds match native labels" checkCertificates,
      testCase "all native script kinds match native labels" checkScripts,
      testCase "all votes and voter authorities match native labels" checkVoting
    ]

label :: CUInt -> Word32 -> IO Text
label category number = Text.pack <$> (nativeLabel category number >>= peekCString)

-- | All encoders emit an array whose first word is its domain discriminant.
kind :: ByteString.ByteString -> IO Word32
kind bytes = case Read.deserialiseFromBytes (Decode.decodeListLenOrIndef >> Decode.decodeWord32) (Lazy.fromStrict bytes) of
  Left failure -> fail (show failure)
  Right (_, number) -> pure number

checkNetworks :: IO ()
checkNetworks = do
  [Network.mainnet, Network.preprod, Network.preview, Network.sanchonet] @?= [764824073, 1, 2, 4]
  forM_ [Network.mainnet, Network.preprod, Network.preview, Network.sanchonet, 0, 3, maxBound] $ \magic ->
    label 0 magic >>= (@?= Network.name magic)

checkCertificates :: IO ()
checkCertificates = forM_ [0, 17, 255] $ \seed -> do
  certificates <- either (fail . show) pure (Certificates.sampleCertificates seed maxBound)
  forM_ certificates $ \certificate -> do
    tag <- kind (Certificate.encodeCbor certificate)
    label 1 tag >>= (@?= Display.certificateKind certificate)

checkScripts :: IO ()
checkScripts = do
  scripts <- Scripts.nativeValues
  forM_ scripts $ \script -> do
    tag <- kind (Native.encodeCbor script)
    label 2 tag >>= (@?= Display.nativeScriptKind script)

checkVoting :: IO ()
checkVoting = do
  forM_ [minBound .. maxBound] $ \choice ->
    label 3 (fromIntegral (fromEnum choice)) >>= (@?= Display.vote choice)
  key <- either (fail . show) pure (Credential.keyHashFromBytes (ByteString.replicate 28 1))
  drep <- either (fail . show) pure (Credential.keyHashFromBytes (ByteString.replicate 28 2))
  pool <- either (fail . show) pure (Credential.keyHashFromBytes (ByteString.replicate 28 3))
  committeeScript <- either (fail . show) pure (Credential.scriptHashFromBytes (ByteString.replicate 28 4))
  drepScript <- either (fail . show) pure (Credential.scriptHashFromBytes (ByteString.replicate 28 5))
  let voters = [Voting.CommitteeVoter (Credential.KeyCredential key), Voting.CommitteeVoter (Credential.ScriptCredential committeeScript), Voting.DRepVoter (Credential.KeyCredential drep), Voting.DRepVoter (Credential.ScriptCredential drepScript), Voting.StakePoolVoter pool]
  forM_ voters $ \voter -> do
    tag <- kind (Voting.encodeVoter voter)
    label 4 tag >>= (@?= Display.voterKind voter)
