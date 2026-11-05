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

-- | Pinned native golden vectors. See Scripts.md for provenance.
module Fixtures.Scripts (applyVectors, compiledScript, nativeVectors) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString

-- | A canonical serialized identity program from the native binding corpus.
compiledScript :: ByteString
compiledScript = ByteString.pack [0x45, 0x01, 0x00, 0x00, 0x24, 0x99]

-- | Parameters encoded as CBOR with expected serialized program bytes.
applyVectors :: [(String, String)]
applyVectors =
  [ ("80", "450100002499"),
    ("8100", "4b0100003249930101000001"),
    ("81c249010000000000000000", "55010000324993010bc2490100000000000000000001"),
    ("820041ff", "5201000033249930010100004c010241ff0001")
  ]

-- | All native tags, including nested Dijkstra key/script guards.
nativeVectors :: [String]
nativeVectors =
  [ "8200581c00112233445566778899aabbccddeeff00112233445566778899aabb",
    "820180",
    "820280",
    "83030080",
    "820400",
    "82051bffffffffffffffff",
    "82068200581c00112233445566778899aabbccddeeff00112233445566778899aabb",
    "82068201581caabbccddeeff00112233445566778899aabbccddeeff001122334455",
    "8201828200581c00112233445566778899aabbccddeeff00112233445566778899aabb82068200581c00112233445566778899aabbccddeeff00112233445566778899aabb",
    "82028182068201581caabbccddeeff00112233445566778899aabbccddeeff001122334455",
    "8303018182068200581c00112233445566778899aabbccddeeff00112233445566778899aabb"
  ]
