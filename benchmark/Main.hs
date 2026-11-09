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

-- | Small offline wall-clock baselines, not a statistical benchmark suite.
-- Run an optimized build with an optional positive iteration count (default 100):
-- @cabal bench cometa-performance --benchmark-options="1000 +RTS -s -RTS"@.
-- RTS statistics include setup and all operations, and exclude native allocations.
module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Address as Address
import qualified Cometa.Address.Shelley as Shelley
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
import Cometa.Error (Error)
import qualified Cometa.NetworkId as Network
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Input as Input
import qualified Cometa.Transaction.Inspection as Inspection
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Signing as Signing
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as TxId
import qualified Cometa.Value as Value
import Control.Exception (evaluate)
import Control.Monad.Trans.Except (except, runExceptT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef (newIORef, readIORef)
import qualified Fixtures.ProtocolParameters as Fixture
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getArgs)
import System.Exit (die)
import System.Mem (performGC)
import Text.Printf (printf)
import Text.Read (readMaybe)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  iterations <- getArgs >>= parseIterations
  (config, plan) <- paymentFixture >>= require
  transaction <- Builder.build config plan >>= require
  encoded <- evaluate (Tx.encodeCbor transaction)
  -- Reading the fixed input through IO on every iteration prevents a shared
  -- decode/encode thunk from replacing repeated work under optimization.
  encodedInput <- newIORef encoded
  printf "Offline baseline: %d iterations per operation; one untimed warm-up each.\n" iterations
  putStrLn "Times include result consumption and loop overhead; no network is used."
  measure iterations "native payment build" $ do
    built <- Builder.build config plan >>= require
    consumeBytes (Tx.encodeCbor built)
  -- Synthetic public fixture bytes only. Acquire once, outside signing timing.
  result <- SigningKey.withNormalKey (Bytes.replicate 32 7) $ \key -> do
    measure iterations "native transaction signing" $ do
      signed <- Signing.sign key transaction >>= require
      consumeBytes (Tx.encodeCbor signed)
    pure (Right ())
  require result
  measure iterations "native inspection + JSON encode" $ do
    inspected <- Inspection.transaction transaction >>= require
    evaluate (Lazy.foldl' (\total byte -> total + fromIntegral byte) (0 :: Int) (Aeson.encode inspected))
  measure iterations "CBOR decode + exact encode" $ do
    input <- readIORef encodedInput
    decoded <- require (Tx.decodeCbor input)
    consumeBytes (Tx.encodeCbor decoded)

-- | Validate CLI input before fixture setup. A bounded Int also bounds the loop.
parseIterations :: [String] -> IO Int
parseIterations arguments = case arguments of
  [] -> pure 100
  [argument] -> case readMaybe argument of
    Just count | count > 0 -> pure count
    _ -> usage
  _ -> usage
  where
    usage = die "Usage: cometa-performance [positive-iterations] [+RTS -s -RTS]"

-- | Traverse every output byte, forcing serialization within the timed action.
consumeBytes :: Bytes.ByteString -> IO Int
consumeBytes = evaluate . Bytes.foldl' (\total byte -> total + fromIntegral byte) 0

-- | Warm once, collect before timing, and retain an observed strict checksum.
-- Fixed input measures repeated execution with warm caches. Decode preserves
-- original component bytes; this is not a canonicalizing re-encoder baseline.
measure :: Int -> String -> IO Int -> IO ()
measure iterations label action = do
  _ <- action
  performGC
  start <- getMonotonicTimeNSec
  checksum <- loop iterations 0
  end <- getMonotonicTimeNSec
  let elapsed = fromIntegral (end - start) / 1000000 :: Double
  printf "%s: %.3f ms total, %.3f us/op (checksum %d)\n" label elapsed (elapsed * 1000 / fromIntegral iterations) checksum
  where
    loop remaining checksum
      | remaining == 0 = pure checksum
      | otherwise = do
          observed <- action
          next <- evaluate (checksum + observed)
          loop (remaining - 1) next

-- | Stop on unexpected fixture/native failures instead of timing error paths.
require :: (Show failure) => Either failure value -> IO value
require = either (die . show) pure

-- | Prepare the same small payment shape as the offline building example.
-- The full-field parameter fixture is synthetic and is not a network snapshot.
paymentFixture :: IO (Either Error (Builder.Config, Plan.Plan))
paymentFixture = runExceptT $ do
  raw <- except Fixture.parameters
  key <- except (Credential.keyHashFromBytes (Bytes.replicate 28 7))
  previous <- except (TxId.fromBytes (Bytes.replicate 32 8))
  let destination = Address.ShelleyAddress (Shelley.enterprise Network.testnet (Credential.KeyCredential key))
      parameters =
        raw
          { Parameters.parameterMinFeeA = 44,
            Parameters.parameterMinFeeB = 155381,
            Parameters.parameterMaxTxSize = 16384,
            Parameters.parameterMaxValueSize = Just 5000,
            Parameters.parameterAdaPerUtxoByte = Just 4310,
            Parameters.parameterProtocolVersion = Version.ProtocolVersion 10 0
          }
  funding <- except (Output.mkOutput destination (Value.lovelace 10000000) Datum.NoDatum Nothing)
  payment <- except (Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing)
  let config =
        (Builder.defaultConfig parameters Slot.preview destination)
          { Builder.availableUtxos = [Utxo.utxo (Input.input previous 0) funding]
          }
  pure (config, Plan.payTo payment <> Plan.validUntil 1000000)
