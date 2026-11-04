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

-- | Public transaction bytes and independent expected results. Provenance and
-- reproduction details are recorded in test/Fixtures/TRANSACTIONS.md.
module Fixtures.Transaction
  ( Fixture (..),
    historical,
    noncanonical,
    rich,
    allFixtures,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

-- TYPES ----------------------------------------------------------------------

data Fixture = Fixture
  { fixtureName :: String,
    transactionHex :: Text,
    bodyHex :: Text,
    witnessHex :: Text,
    hashHex :: Text,
    expectedFee :: Word64,
    -- Counts: vkeys, bootstrap, native scripts, datums, redeemers, verified vkeys.
    expectedCounts :: [Word64]
  }

-- DEFINITIONS ----------------------------------------------------------------

allFixtures :: [Fixture]
allFixtures = [historical, noncanonical, rich]

historical :: Fixture
historical =
  Fixture
    { fixtureName = "Historical Shelley 3-element envelope",
      transactionHex =
        Text.concat
          [ "83a50081825820bf30608a974d09c56dd62ca10199ec11746ea2d90dbd83649d4f37c629b1ba840001818258390117d2",
            "37fb8f952c995cd28f73c555adc2307322d819b7f565196ce754348144bff68f23c1386b85dea0f8425ca574b1a11e18",
            "8ffaba67537c1a0048f96f021a000351d1031a019732f30682a7581c162f94554ac8c225383a2248c245659eda870eaa",
            "82d0ef25fc7dcd82a10d8100581c2075a095b3c844a29c24317a94a643ab8e22d54a3a3a72a420260af6a10d8100581c",
            "268cfc0b89e910ead22e0ade91493d8212f53f3e2164b2e4bef0819ba10d8100581c60baee25cbc90047e83fd01e1e57",
            "dc0b06d3d0cb150d0ab40bbfead1a10d8100581cad5463153dc3d24b9ff133e46136028bdc1edbb897f5a7cf1b37950c",
            "a10d8100581cb9547b8a57656539a8d9bc42c008e38d9c8bd9c8adbb1e73ad529497a10d8100581cf7b341c14cd58fca",
            "4195a9b278cce1ef402dc0e06deb77e543cd1757a10d8100190103a1008882582061261a95b7613ee6bf2067dad77b70",
            "349729b0c50d57bc1cf30de0db4a1e73a858407d72721e7504e12d50204f7d9e9d9fe60d9c6a4fd18ad629604729df4f",
            "7f3867199b62885623fab68a02863e7877955ca4a56c867157a559722b7b350b668a0b8258209180d818e69cd997e346",
            "63c418a648c076f2e19cd4194e486e159d8580bc6cda5840af668e57c98f0c3d9b47c66eb9271213c39b4ea1b4d543b0",
            "892f03985edcef4216d1f98f7b731eedc260a2154124b5cab015bfeaf694d58966d124ad2ff60f0382582089c29f8c4a",
            "f27b7accbe589747820134ebbaa1caf3ce949270a3d0c7dcfd541b58401ad69342385ba6c3bef937a79456d7280c0d53",
            "9128072db15db120b1579c46ba95d18c1fa073d7dbffb4d975b1e02ebb7372936940cff0a96fce950616d2f504825820",
            "f14f712dc600d793052d4842d50cefa4e65884ea6cf83707079eb8ce302efc855840638f7410929e7eab565b1451effd",
            "fbeea2a8839f7cfcc4c4483c4931d489547a2e94b73e4b15f8494de7f42ea31e573c459a9a7e5269af17b0978e70567d",
            "e80e8258208b53207629f9a30e4b2015044f337c01735abe67243c19470c9dae8c7b73279858400c4ed03254c33a1925",
            "6b7a3859079a9b75215cad83871a9b74eb51d8bcab52911c37ea5c43bdd212d006d1e6670220ff1d03714addf94f490e",
            "482edacbb08f068258205fddeedade2714d6db2f9e1104743d2d8d818ecddc306e176108db14caadd4415840bf48f5dd",
            "577b5cb920bfe60e13c8b1b889366c23e2f2e28d51814ed23def3a0ff4a1964f806829d40180d83b5230728409c1f18d",
            "db5a61c44e614b823bd43f01825820cbc6b506e94fbefe442eecee376f3b3ebaf89415ef5cd2efb666e06ddae4839358",
            "4089bff8f81a20b22f2c3f8a2288b15f1798b51f3363e0437a46c0a2e4e283b7c1018eba0b2b192d6d522ac8df2f2e95",
            "b4c8941b387cda89857ab0ae77db14780c825820e8c03a03c0b2ddbea4195caf39f41e669f7d251ecf221fbb2f275c0a",
            "5d7e05d158402643ac53dd4da4f6e80fb192b2bf7d1dd9a333bbacea8f07531ba450dd8fb93e481589d370a6ef33a97e",
            "03b2f5816e4b2c6a8abf606a859108ba6f416e530d07f6"
          ],
      bodyHex =
        Text.concat
          [ "a50081825820bf30608a974d09c56dd62ca10199ec11746ea2d90dbd83649d4f37c629b1ba840001818258390117d237",
            "fb8f952c995cd28f73c555adc2307322d819b7f565196ce754348144bff68f23c1386b85dea0f8425ca574b1a11e188f",
            "faba67537c1a0048f96f021a000351d1031a019732f30682a7581c162f94554ac8c225383a2248c245659eda870eaa82",
            "d0ef25fc7dcd82a10d8100581c2075a095b3c844a29c24317a94a643ab8e22d54a3a3a72a420260af6a10d8100581c26",
            "8cfc0b89e910ead22e0ade91493d8212f53f3e2164b2e4bef0819ba10d8100581c60baee25cbc90047e83fd01e1e57dc",
            "0b06d3d0cb150d0ab40bbfead1a10d8100581cad5463153dc3d24b9ff133e46136028bdc1edbb897f5a7cf1b37950ca1",
            "0d8100581cb9547b8a57656539a8d9bc42c008e38d9c8bd9c8adbb1e73ad529497a10d8100581cf7b341c14cd58fca41",
            "95a9b278cce1ef402dc0e06deb77e543cd1757a10d8100190103"
          ],
      witnessHex =
        Text.concat
          [ "a1008882582061261a95b7613ee6bf2067dad77b70349729b0c50d57bc1cf30de0db4a1e73a858407d72721e7504e12d",
            "50204f7d9e9d9fe60d9c6a4fd18ad629604729df4f7f3867199b62885623fab68a02863e7877955ca4a56c867157a559",
            "722b7b350b668a0b8258209180d818e69cd997e34663c418a648c076f2e19cd4194e486e159d8580bc6cda5840af668e",
            "57c98f0c3d9b47c66eb9271213c39b4ea1b4d543b0892f03985edcef4216d1f98f7b731eedc260a2154124b5cab015bf",
            "eaf694d58966d124ad2ff60f0382582089c29f8c4af27b7accbe589747820134ebbaa1caf3ce949270a3d0c7dcfd541b",
            "58401ad69342385ba6c3bef937a79456d7280c0d539128072db15db120b1579c46ba95d18c1fa073d7dbffb4d975b1e0",
            "2ebb7372936940cff0a96fce950616d2f504825820f14f712dc600d793052d4842d50cefa4e65884ea6cf83707079eb8",
            "ce302efc855840638f7410929e7eab565b1451effdfbeea2a8839f7cfcc4c4483c4931d489547a2e94b73e4b15f8494d",
            "e7f42ea31e573c459a9a7e5269af17b0978e70567de80e8258208b53207629f9a30e4b2015044f337c01735abe67243c",
            "19470c9dae8c7b73279858400c4ed03254c33a19256b7a3859079a9b75215cad83871a9b74eb51d8bcab52911c37ea5c",
            "43bdd212d006d1e6670220ff1d03714addf94f490e482edacbb08f068258205fddeedade2714d6db2f9e1104743d2d8d",
            "818ecddc306e176108db14caadd4415840bf48f5dd577b5cb920bfe60e13c8b1b889366c23e2f2e28d51814ed23def3a",
            "0ff4a1964f806829d40180d83b5230728409c1f18ddb5a61c44e614b823bd43f01825820cbc6b506e94fbefe442eecee",
            "376f3b3ebaf89415ef5cd2efb666e06ddae48393584089bff8f81a20b22f2c3f8a2288b15f1798b51f3363e0437a46c0",
            "a2e4e283b7c1018eba0b2b192d6d522ac8df2f2e95b4c8941b387cda89857ab0ae77db14780c825820e8c03a03c0b2dd",
            "bea4195caf39f41e669f7d251ecf221fbb2f275c0a5d7e05d158402643ac53dd4da4f6e80fb192b2bf7d1dd9a333bbac",
            "ea8f07531ba450dd8fb93e481589d370a6ef33a97e03b2f5816e4b2c6a8abf606a859108ba6f416e530d07"
          ],
      hashHex = "fc863a441b55acceebb7d25c81ff7259e4fc9b92fbdf6d594118fb8f1110a78c",
      expectedFee = 217553,
      expectedCounts = [8, 0, 0, 0, 0, 8]
    }

noncanonical :: Fixture
noncanonical =
  Fixture
    { fixtureName = "Synthetic signed noncanonical body",
      transactionHex =
        Text.concat
          [ "84a30219000a018000d9010280a1008182582003a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc866412",
            "5531b85840dc836ca35ce76211f3e2c28b6bbae69086ac3d40734865202771b7c30973c1e05ad9ce2c9bb2192851e79b",
            "a1354d96e323e8c37c81958c103e49f47a801a820af5f6"
          ],
      bodyHex =
        Text.concat
          [ "a30219000a018000d9010280"
          ],
      witnessHex =
        Text.concat
          [ "a1008182582003a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b85840dc836ca35ce76211",
            "f3e2c28b6bbae69086ac3d40734865202771b7c30973c1e05ad9ce2c9bb2192851e79ba1354d96e323e8c37c81958c10",
            "3e49f47a801a820a"
          ],
      hashHex = "6715bbd7c4477c3cc6dd32e3f8e3c513c136dd4cef9d58a275fe1e3b04a6e50b",
      expectedFee = 10,
      expectedCounts = [1, 0, 0, 0, 0, 1]
    }

rich :: Fixture
rich =
  Fixture
    { fixtureName = "Synthetic signed noncanonical body with script, bootstrap, datum and redeemer",
      transactionHex =
        Text.concat
          [ "84a30219000a018000d9010280a5008182582003a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc866412",
            "5531b85840dc836ca35ce76211f3e2c28b6bbae69086ac3d40734865202771b7c30973c1e05ad9ce2c9bb2192851e79b",
            "a1354d96e323e8c37c81958c103e49f47a801a820a01d90102818200581c111111111111111111111111111111111111",
            "11111111111111111111028184582003a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b858",
            "40dc836ca35ce76211f3e2c28b6bbae69086ac3d40734865202771b7c30973c1e05ad9ce2c9bb2192851e79ba1354d96",
            "e323e8c37c81958c103e49f47a801a820a58202222222222222222222222222222222222222222222222222222222222",
            "22222241a004d9010281182a05a182000082182a820a14f5a1017803617578"
          ],
      bodyHex =
        Text.concat
          [ "a30219000a018000d9010280"
          ],
      witnessHex =
        Text.concat
          [ "a5008182582003a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b85840dc836ca35ce76211",
            "f3e2c28b6bbae69086ac3d40734865202771b7c30973c1e05ad9ce2c9bb2192851e79ba1354d96e323e8c37c81958c10",
            "3e49f47a801a820a01d90102818200581c11111111111111111111111111111111111111111111111111111111028184",
            "582003a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b85840dc836ca35ce76211f3e2c28b",
            "6bbae69086ac3d40734865202771b7c30973c1e05ad9ce2c9bb2192851e79ba1354d96e323e8c37c81958c103e49f47a",
            "801a820a5820222222222222222222222222222222222222222222222222222222222222222241a004d9010281182a05",
            "a182000082182a820a14"
          ],
      hashHex = "6715bbd7c4477c3cc6dd32e3f8e3c513c136dd4cef9d58a275fe1e3b04a6e50b",
      expectedFee = 10,
      expectedCounts = [1, 1, 1, 1, 1, 1]
    }
