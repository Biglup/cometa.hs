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

-- | Offline registration assembly, serialization, reload and independent update.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Credential as Credential
import Cometa.Error (Error)
import qualified Cometa.NetworkId as Network
import qualified Cometa.Pool.Metadata as Metadata
import qualified Cometa.Pool.Parameters as Pool
import qualified Cometa.Pool.Relay as Relay
import qualified Cometa.UnitInterval as Unit
import qualified Data.ByteString as ByteString
import qualified Data.Set as Set
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- | Public fixture hashes, without signing keys, network access or submission.
registration :: Either Error Pool.PoolParameters
registration = do
  operator <- Credential.keyHashFromBytes (ByteString.replicate 28 1)
  owner <- Credential.keyHashFromBytes (ByteString.replicate 28 2)
  vrf <- Pool.vrfKeyHashFromBytes (ByteString.replicate 32 3)
  margin <- Unit.mkUnitInterval 1 20
  dns <- Relay.mkDnsName "relay.example.com"
  location <- Metadata.mkUrl "https://example.com/pool.json"
  digest <- Metadata.metadataHashFromBytes (ByteString.replicate 32 4)
  pure
    Pool.PoolParameters
      { Pool.operator = operator,
        Pool.vrfKeyHash = vrf,
        Pool.blsKey = Nothing,
        Pool.pledge = 100000000,
        Pool.cost = 340000000,
        Pool.margin = margin,
        Pool.rewardAccount = Reward.fromCredential Network.testnet (Credential.KeyCredential owner),
        Pool.owners = Set.singleton owner,
        Pool.relays = [Relay.SingleHostName (Just 3001) dns],
        Pool.metadata = Just (Metadata.Metadata location digest)
      }

-- | Serialize and decode through one validation boundary before editing.
workflow :: Either Error (Bool, Int)
workflow = do
  parameters <- registration
  restored <- Pool.decodeCbor (Pool.encodeCbor parameters)
  let updated = restored {Pool.metadata = Nothing}
      certificate = Certificate.PoolRegistration updated
  pure (restored == parameters, ByteString.length (Certificate.encodeCbor certificate))

main :: IO ()
main = either (die . show) print workflow
