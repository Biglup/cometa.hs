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

-- | Published deterministic test keys, never application keys. Intentionally no
-- Show instance: test diagnostics identify a vector by name, not key material.
-- Attribution and independent checks are in test/Fixtures/ED25519.md.
module Fixtures.Ed25519
  ( Vector (..),
    rfcVectors,
    normalVector,
    extendedVector,
    allVectors,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Data.Text (Text)
import qualified Data.Text as Text

-- TYPES ----------------------------------------------------------------------

data Vector = Vector
  { vectorName :: String,
    isExtended :: Bool,
    privateHex :: Text,
    publicHex :: Text,
    messageHex :: Text,
    signatureHex :: Text,
    publicHashHex :: Text
  }

-- DEFINITIONS ----------------------------------------------------------------

allVectors :: [Vector]
allVectors = rfcVectors ++ [normalNulVector, extendedVector, extendedEmptyVector, extendedNulVector]

normalVector :: Vector
normalVector = rfc1

rfcVectors :: [Vector]
rfcVectors = [rfc1, rfc2, rfc3, rfc1023]

rfc1 :: Vector
rfc1 =
  Vector
    { vectorName = "RFC 8032 TEST 1",
      isExtended = False,
      privateHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
      publicHex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
      messageHex = "",
      signatureHex =
        Text.concat
          [ "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46b",
            "d25bf5f0595bbe24655141438e7a100b"
          ],
      publicHashHex = "35dedd2982a03cf39e7dce03c839994ffdec2ec6b04f1cf2d40e61a3"
    }

rfc2 :: Vector
rfc2 =
  Vector
    { vectorName = "RFC 8032 TEST 2",
      isExtended = False,
      privateHex = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
      publicHex = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
      messageHex = "72",
      signatureHex =
        Text.concat
          [ "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c",
            "387b2eaeb4302aeeb00d291612bb0c00"
          ],
      publicHashHex = "977efb35ab621d39dbeb7274ec7795a34708ff4d25a01a1df04c1f27"
    }

rfc3 :: Vector
rfc3 =
  Vector
    { vectorName = "RFC 8032 TEST 3",
      isExtended = False,
      privateHex = "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
      publicHex = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
      messageHex = "af82",
      signatureHex =
        Text.concat
          [ "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc659",
            "4a7c15e9716ed28dc027beceea1ec40a"
          ],
      publicHashHex = "7f8a76c0ebaa4ad20dfdcd51a5de070ab771f4bf377f2c41e6b71c0a"
    }

rfc1023 :: Vector
rfc1023 =
  Vector
    { vectorName = "RFC 8032 TEST 1024",
      isExtended = False,
      privateHex = "f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5",
      publicHex = "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
      messageHex =
        Text.concat
          [ "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1",
            "e355f6c50544e23fb1433ddf73be84d879de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d",
            "658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc1a858efcb8550ee3a5e1998bd177e93a",
            "7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e",
            "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc10",
            "3b6621fcde2beca1231d206be6cd9ec7aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1",
            "85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2d17ba70eb6248e594e1a2297acbbb39d",
            "502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270",
            "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089b",
            "eccf80cfe2df16a2cf65bd92dd597b0707e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba",
            "b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51addd3b75a2b1ae0784504df543af8969b",
            "e3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7",
            "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988d",
            "cda6f3bfd15c4b4c4525004aa06eeff8ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df",
            "f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08d78ff4ef5d63653a65040cf9bfd4aca7",
            "984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4",
            "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac09",
            "43bf6686b64b2579376504ccc493d97e6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f",
            "b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b50d334ba77c225bc307ba537152f3f161",
            "0e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d",
            "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8ca",
            "c60c905c15fc910840b94c00a0b9d0"
          ],
      signatureHex =
        Text.concat
          [ "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b",
            "5e8fcd4f681e30a6ac00a9704a188a03"
          ],
      publicHashHex = "3fa478a09cf841058b3e63abe2cfc50aac0ea46d84eaa50a6ae5accc"
    }

extendedVector :: Vector
extendedVector =
  Vector
    { vectorName = "cardano-c extended Ed25519",
      isExtended = True,
      privateHex =
        Text.concat
          [ "a0ab55b174ba8cd95e2362d035f377b4dc779a0fae65767e3b8dd790fa748250f3ef2cc372c207d7902607ffef01872a",
            "4c785cd27e7342de7f4332f2d5fdc3a8"
          ],
      publicHex = "311f8914b8934efbe7cbb8cc4745853de12e8ea402df6f9f69b18d2792c6bed8",
      messageHex =
        Text.concat
          [ "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd",
            "454d4423643ce80e2a9ac94fa54ca49f"
          ],
      signatureHex =
        Text.concat
          [ "843aa4353184193bdf01aab7f636ac53f86746dd97a2a2e01fe7923c37bfec40b68a73881a26ba57dc974abc1123d086",
            "6b542a5447e03677134a8f4e1db2bc0c"
          ],
      publicHashHex = "ebf46bc374bda5b937d4d964fc0b73e940a9ea7d8cfdf39162a6f207"
    }

extendedEmptyVector :: Vector
extendedEmptyVector =
  extendedVector
    { vectorName = "extended empty message",
      messageHex = "",
      signatureHex = "d54ebb1afebf7f0d7ef9cafeb318c0880a8b5eeb902cfe42a5e3610d3a3a9223b133125792a0f5be3e2e40f58fd71516eda072cd35f577d1c25e1575482db80c"
    }

extendedNulVector :: Vector
extendedNulVector =
  extendedVector
    { vectorName = "extended embedded NUL",
      messageHex = "000100ff",
      signatureHex = "091f234d061be3ff73151fb832d342b7a490ff6f1c79907658e3c610d06d6827a663cbbd6474171703012c4495a1a79d998a2faa22df598bfa21e5b96fd9130a"
    }

normalNulVector :: Vector
normalNulVector =
  rfc1
    { vectorName = "normal embedded NUL",
      messageHex = "000100ff",
      signatureHex = "d6bea3eb43f22edff0d0669474dada1fb561ced14a8e25356e1f875db02f23e37c48b2ae101aecd78e2a471e68ce03af64f25c070c39b446cdc10f6adf4c3107"
    }
