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

-- | Assemble DRep registration and delegation, then reload their stored bytes.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Certificate as Certificate
import qualified Cometa.Certificate.Collection as Certificates
import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.Governance.Anchor as Anchor
import qualified Cometa.Governance.DRep as DRep
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = case prepareCertificates of
  Left failure -> die (show failure)
  Right (stored, reloaded) -> do
    putStrLn ("Certificates: " <> show (length (Certificates.toList (Certificates.toCertificates reloaded))))
    putStrLn ("Exact stored bytes retained: " <> show (stored == Certificates.toCbor reloaded))

prepareCertificates :: Either Error (ByteString.ByteString, Certificates.EncodedCertificates)
prepareCertificates = do
  -- Demonstration hashes only; deposits must come from current protocol parameters.
  representative <- Credential.keyHashFromBytes (ByteString.replicate 28 1)
  staking <- Credential.keyHashFromBytes (ByteString.replicate 28 2)
  location <- Anchor.mkUrl "https://example.com/drep.json"
  digest <- Anchor.dataHashFromBytes (ByteString.replicate 32 3)

  let authority = Credential.KeyCredential representative
      metadata = Anchor.Anchor location digest
      registration = Certificate.RegisterDRep authority 500000000 (Just metadata)
      delegation = Certificate.VoteDelegation (Credential.KeyCredential staking) (DRep.DRepCredential authority)
      certificates = Certificates.fromList [registration, delegation]
      stored = Certificates.encodeCbor certificates

  reloaded <- Certificates.decodeCbor stored
  pure (stored, reloaded)
