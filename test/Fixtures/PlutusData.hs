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

-- | Pinned native integer encodings and independent expected datum digests.
module Fixtures.PlutusData (integerVectors) where

-- DEFINITIONS ----------------------------------------------------------------

integerVectors :: [(Integer, String, String)]
integerVectors =
  [ (-9223372036854775809, "3b8000000000000000", "e2a47752ef4828f7483c5026a4bc7ed4e452f8101dcf82864f1b1e907c60c572"),
    (-18446744073709551616, "3bffffffffffffffff", "69393b55a0ae218f47bfa0376159277a159c76662f738592c1553e3d904c5ac7"),
    (-18446744073709551617, "c349010000000000000000", "42e2692b0e46ba0dc699ee2f1aa07e1bffb800c35c7b138ddb756d8bf998bc89"),
    (-18446744073709551618, "c349010000000000000001", "4030e370c7a0cb0efdeb05c42cca353d0740f9fc7f05f9a585c69b0850208e30"),
    (-340282366920938463463374607431768211456, "c350ffffffffffffffffffffffffffffffff", "ffab25cae61e7a695eff9e2b32281b5e0eea2096242c598d6236b0c551751c44"),
    (340282366920938463463374607431768211456, "c2510100000000000000000000000000000000", "4ea513acfa0740583f1c5abc413d985ad01c48d3d62e0d65b8721e3de8390a3d"),
    (18446744073709551616, "c249010000000000000000", "0b854352f6a4c02db6f13ac878a41f0b11f54950ad9b88170fb509c916ff0a71"),
    (-13407807929942597099574024998205846127479365820592393377723561443721764030073546976801874298166903427690031858186486050853753882811946569946433649006084096, "c35840ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "8e07c147a103e69aadc9be059aeed25e358741ff27f5496e0322f17f0d6d8cf2"),
    (-13407807929942597099574024998205846127479365820592393377723561443721764030073546976801874298166903427690031858186486050853753882811946569946433649006084097, "c35f5840010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004100ff", "8e7a1e2d24d1199e843eaeecff59890724e47f712c32ac9f2c3547b794e8285d")
  ]
