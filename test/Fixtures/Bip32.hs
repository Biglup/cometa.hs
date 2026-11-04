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

-- | Deterministic test material; see BIP32.md for pinned provenance.
module Fixtures.Bip32 (privateHex, publicHex, hardChildHex, softRootHex, softChildHex, softPublicHex, softPublicChildHex, entropyHex, entropyRootHex, emptyPasswordRootHex, nulPasswordRootHex, publicHashHex) where

-- IMPORTS --------------------------------------------------------------------

import Data.Text (Text)

-- DEFINITIONS ----------------------------------------------------------------

privateHex :: Text
privateHex = "a0ab55b174ba8cd95e2362d035f377b4dc779a0fae65767e3b8dd790fa748250f3ef2cc372c207d7902607ffef01872a4c785cd27e7342de7f4332f2d5fdc3a8d0c110e1d6a061d3558eb6a3138a3982253c6616e1bf4d8bd31e92de8328affe"

publicHex :: Text
publicHex = "311f8914b8934efbe7cbb8cc4745853de12e8ea402df6f9f69b18d2792c6bed8d0c110e1d6a061d3558eb6a3138a3982253c6616e1bf4d8bd31e92de8328affe"

hardChildHex :: Text
hardChildHex = "3809937b61bd4f180a1e9bd15237e7bc20e36b9037dd95ef60d84f6004758250a22e1bfc0d81e9adb7760bcba7f5214416b3e9f27c8d58794a3a7fead2d5b6958d515cb54181fb2f5fc3af329e80949c082fb52f7b07e359bd7835a6762148bf"

softRootHex :: Text
softRootHex = "d8287e922756977dc0b79659e6eebcae3a1fb29a22ce1449c94f125462586951390af99a0350130451e9bf4f4691f37c352dc7025d52d9132f61a82f61d3803d00b5f1652f5cbe257e567c883dc2b16e0a9568b19c5b81ea8bd197fc95e8bdcf"

softChildHex :: Text
softChildHex = "08f9d7de597d31fade994b8a1e9d3e3afe53ac8393297e8f4d96225d725869517ae54c631588abb408fcab0676a4da6b60c82b3a3d7045a26a576c7901e5e9579db12d11a3559131a47f51f854a6234725ab8767d3fcc4c9908be55508f3c712"

softPublicHex :: Text
softPublicHex = "6fd8d9c696b01525cc45f15583fc9447c66e1c71fd1a11c8885368404cd0a4ab00b5f1652f5cbe257e567c883dc2b16e0a9568b19c5b81ea8bd197fc95e8bdcf"

softPublicChildHex :: Text
softPublicChildHex = "b857a8cd1dbbfed1824359d9d9e58bc8ffb9f66812b404f4c6ffc315629835bf9db12d11a3559131a47f51f854a6234725ab8767d3fcc4c9908be55508f3c712"

entropyHex :: Text
entropyHex = "caec96d09fc2020ab230199e0188cd6a554e2da2cba32de9ff6c0908c7f04d65"

entropyRootHex :: Text
entropyRootHex = "60292301b8dd20a74b58a0bd4ecdeb244a95e757c7a2d25962ada75e271d045ff827c85a5530bfe76975b4189c5fd6d32d4fe43c81373f386fde2fa0e6d0255a2ac1f1560a893ea7937c5bfbfdeab459b1a396f1174b9c5a673a640d01880c35"

emptyPasswordRootHex :: Text
emptyPasswordRootHex = "60ce7dbec3616e9fc17e0c32578b3f380337b1b61a1f3cb9651aee30670e6f53970419a23a2e4e4082d12bf78faa8645dfc882cee2ae7179e2b07fe88098abb2072310084784c7308182dbbdb1449b2706586f1ff5cbf13d15e9b6e78c15f067"

nulPasswordRootHex :: Text
nulPasswordRootHex = "f834649918cd8633584736a4778d99c22c0f5444ca493e26d78bf8fb785f3c51d227b626bad5ad23212265a292bf72499b96a4f40e47fa6aac84b22411f58d4592e48c3cb808d1b79e3529d4770b930b6b836c5ffbdce8a193fd3d8eab0e82b4"

publicHashHex :: Text
publicHashHex = "b9b5e117f1c14f503128385392f9b37f224d6d1a715d680f46a0ced1"
