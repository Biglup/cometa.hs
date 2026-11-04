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

module DerivationPath (tests) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PrivateKey as Private
import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import Control.Monad (when)
import Data.Bits ((.|.))
import qualified Data.ByteString as ByteString
import Data.Word (Word32, Word64, Word8)
import qualified Fixtures.Bip32 as Fixture
import Foreign.C.Types (CInt (..), CUInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray)
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, evalEither, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- DEFINITIONS ----------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Derivation paths"
    [ testCase "all CIP-1852 constants match native headers" checkConstants,
      testCase "account paths agree with real software-handler struct consumption" checkHandlerAccount,
      testCase "component bounds preserve exact invalid input" checkBounds,
      testCase "maximum raw fields encode without wraparound" checkMaximumEncoding,
      testCase "standard, multisig, governance and custom paths match native keys" checkNativePaths,
      testProperty "encoding and inspection preserve arbitrary valid components" propEncoding
    ]

checkConstants :: IO ()
checkConstants = allocaArray 9 $ \output -> do
  cConstants output
  values <- peekArray 9 output
  values
    @?= map
      Path.indexValue
      [ Path.cardanoCoinType,
        Path.standardPurpose,
        Path.multisigPurpose,
        Path.externalRole,
        Path.internalRole,
        Path.stakingRole,
        Path.drepRole,
        Path.committeeColdRole,
        Path.committeeHotRole
      ]

checkBounds :: IO ()
checkBounds = do
  mapM_
    (\value -> Path.mkIndex value @?= Left (InvalidDerivationIndex value))
    [-(2 ^ (100 :: Int)), -1, 2147483648, 4294967295, 4294967296, 18446744073709551615, 2 ^ (100 :: Int)]
  mapM_
    (\value -> fmap Path.indexValue (Path.mkIndex value) @?= Right (fromInteger value))
    [0, 1, 2147483647]

checkMaximumEncoding :: IO ()
checkMaximumEncoding = do
  maximumIndex <- either (fail . show) pure (Path.mkIndex 2147483647)
  let prefix = Path.mkAccountPath maximumIndex maximumIndex maximumIndex
      path = Path.mkDerivationPath prefix maximumIndex maximumIndex

  Path.toIndices path @?= [0xffffffff, 0xffffffff, 0xffffffff, 0x7fffffff, 0x7fffffff]

checkNativePaths :: IO ()
checkNativePaths =
  mapM_
    checkNativePath
    ([[1852, 1815, 0, role, 0] | role <- [0 .. 5]] ++ [[1854, 1815, 7, 0, 42], [123, 456, 789, 17, 29], replicate 5 2147483647])

checkNativePath :: [Integer] -> IO ()
checkNativePath components = case traverse Path.mkIndex components of
  Right [purpose, coin, account, role, index] -> do
    let prefix = Path.mkAccountPath purpose coin account
        path = Path.mkDerivationPath prefix role index
    expected <- nativePublic components False
    expectedAccount <- nativePublic components True
    actual <- require $ Private.withKeyHex Fixture.privateHex $ \root ->
      Private.withDerived root (Path.toIndices path) Private.publicKey
    Public.toBytes actual @?= expected
    accountPublic <- require $ Private.withKeyHex Fixture.privateHex $ \root ->
      Private.withDerived root (Path.accountIndices prefix) Private.publicKey
    Public.toBytes accountPublic @?= expectedAccount
    relative <- require (Public.derive accountPublic (Path.relativeIndices path))
    relative @?= actual
    when (purpose == Path.standardPurpose && coin == Path.cardanoCoinType) $
      Path.mkStandardAccountPath account @?= prefix
  _ -> assertFailure "invalid test components"

nativePublic :: [Integer] -> Bool -> IO ByteString.ByteString
nativePublic components accountOnly = case Hex.decodeHex Fixture.privateHex of
  Nothing -> assertFailure "invalid fixture" >> pure ByteString.empty
  Just bytes -> ByteString.useAsCString bytes $ \input ->
    withArray (map fromInteger components) $ \values -> allocaBytes 64 $ \output -> do
      status <- cPublic (castPtr input) values (if accountOnly then 1 else 0) output
      status @?= 0
      ByteString.packCStringLen (castPtr output, 64)

checkHandlerAccount :: IO ()
checkHandlerAccount = do
  entropy <-
    maybe (fail "invalid fixture entropy") pure $
      Hex.decodeHex "387183ffe785d467ab662c01acbcf79400e2430dde6c9aee74cf0602de0d82e8"
  mapM_ (checkHandlerPrefix entropy) [[1852, 1815, 0], [1854, 1815, 7], [123, 456, 789], replicate 3 2147483647]

checkHandlerPrefix :: ByteString.ByteString -> [Integer] -> IO ()
checkHandlerPrefix entropy values = do
  components <- either (fail . show) pure (traverse Path.mkIndex values)
  case components of
    [purpose, coin, account] -> do
      let prefix = Path.mkAccountPath purpose coin account
      actual <- require $ Private.withEntropy ByteString.empty entropy $ \root ->
        Private.withDerived root (Path.accountIndices prefix) Private.publicKey
      expected <- ByteString.useAsCString entropy $ \input ->
        withArray (map fromInteger values) $ \raw -> allocaBytes 64 $ \output -> do
          status <- cHandlerAccount (castPtr input) raw output
          status @?= 0
          ByteString.packCStringLen (castPtr output, 64)
      Public.toBytes actual @?= expected
      when (values == [1852, 1815, 0]) $
        Public.toHex actual @?= "1b39889a420374e41917cf420d88a84d9b40d7eeef533ac37f323076c5f7106a15ef170481a5c4333be2b4cf498525512ac4a3427e1a0e9c9f42cfcb42ba6deb"
    _ -> assertFailure "invalid account fixture length"

propEncoding :: Property
propEncoding = property $ do
  values <- forAll (Gen.list (Range.singleton 5) (Gen.integral (Range.linear 0 2147483647)))
  components <- evalEither (traverse Path.mkIndex values)
  case components of
    [purpose, coin, account, role, index] -> do
      let prefix = Path.mkAccountPath purpose coin account
          path = Path.mkDerivationPath prefix role index
      map Path.indexValue [Path.purpose prefix, Path.coinType prefix, Path.account prefix, Path.role path, Path.index path]
        === map fromInteger values
      Path.accountPath path === prefix
      Path.accountIndices prefix === map ((.|. 0x80000000) . fromInteger) (take 3 values)
      Path.relativeIndices path === map fromInteger (drop 3 values)
      Path.toIndices path === Path.accountIndices prefix ++ Path.relativeIndices path
    _ -> fail "generator length invariant"

require :: IO (Either Error a) -> IO a
require action = action >>= either (\err -> assertFailure (show err) >> fail "operation failed") pure

-- FOREIGN IMPORTS ------------------------------------------------------------

foreign import ccall unsafe "cometa_test_path_constants"
  cConstants :: Ptr Word32 -> IO ()

foreign import ccall safe "cometa_test_path_public"
  cPublic :: Ptr Word8 -> Ptr Word64 -> CInt -> Ptr Word8 -> IO CUInt

foreign import ccall safe "cometa_test_handler_account"
  cHandlerAccount :: Ptr Word8 -> Ptr Word64 -> Ptr Word8 -> IO CUInt
