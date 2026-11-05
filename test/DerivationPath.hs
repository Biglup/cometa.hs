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

import qualified Cometa.Crypto.Bip32 as Bip32
import qualified Cometa.Crypto.Bip32.PrivateKey as Private
import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error (..))
import qualified Cometa.Internal.Hex as Hex
import Control.Monad (when)
import Data.Bits ((.|.))
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Data.Word (Word32, Word64, Word8)
import qualified Fixtures.Bip32 as Fixture
import Foreign.C.Types (CInt (..), CUInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray)
import Foreign.Ptr (Ptr, castPtr)
import Hedgehog (Property, assert, evalEither, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC)
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
      testCase "public derivation helpers preserve vectors, passwords and snapshots" checkPublicHelpers,
      testCase "public derivation helpers preserve invalid entropy errors" checkHelperErrors,
      testProperty "bounded components agree with validated construction" propBounded,
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
  let maximumIndex = maxBound
      prefix = Path.accountPath maximumIndex maximumIndex maximumIndex
      path = Path.derivationPath prefix maximumIndex maximumIndex

  Path.toIndices path @?= [0xffffffff, 0xffffffff, 0xffffffff, 0x7fffffff, 0x7fffffff]

checkNativePaths :: IO ()
checkNativePaths =
  mapM_
    checkNativePath
    ([[1852, 1815, 0, role, 0] | role <- [0 .. 5]] ++ [[1854, 1815, 7, 0, 42], [123, 456, 789, 17, 29], replicate 5 2147483647])

checkNativePath :: [Integer] -> IO ()
checkNativePath components = case traverse Path.mkIndex components of
  Right [purpose, coin, account, role, index] -> do
    let prefix = Path.accountPath purpose coin account
        path = Path.derivationPath prefix role index
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
      Path.standardAccountPath account @?= prefix
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
      let prefix = Path.accountPath purpose coin account
      actual <- require $ Private.withEntropy ByteString.empty entropy $ \root ->
        Private.withDerived root (Path.accountIndices prefix) Private.publicKey
      expected <- ByteString.useAsCString entropy $ \input ->
        withArray (map fromInteger values) $ \raw -> allocaBytes 64 $ \output -> do
          status <- cHandlerAccount (castPtr input) raw output
          status @?= 0
          ByteString.packCStringLen (castPtr output, 64)
      Public.toBytes actual @?= expected
      helper <- require (Bip32.deriveAccountPublicKey ByteString.empty entropy prefix)
      Public.toBytes helper @?= expected
      when (values == [1852, 1815, 0]) $
        Public.toHex actual @?= "1b39889a420374e41917cf420d88a84d9b40d7eeef533ac37f323076c5f7106a15ef170481a5c4333be2b4cf498525512ac4a3427e1a0e9c9f42cfcb42ba6deb"
    _ -> assertFailure "invalid account fixture length"

checkPublicHelpers :: IO ()
checkPublicHelpers = do
  entropy <- maybe (fail "invalid fixture entropy") pure (Hex.decodeHex Fixture.entropyHex)
  let prefix = Path.standardAccountPath minBound
      path = Path.derivationPath prefix Path.externalRole minBound
      vectors =
        [ ("some_password_@#$%^&", entropy, Fixture.entropyRootHex),
          (ByteString.empty, ByteString.replicate 16 0, Fixture.emptyPasswordRootHex),
          ("a\0b", ByteString.pack [0 .. 31], Fixture.nulPasswordRootHex)
        ]
  mapM_ (checkHelperVector prefix path) vectors

checkHelperVector :: Path.AccountPath -> Path.DerivationPath -> (ByteString.ByteString, ByteString.ByteString, Text.Text) -> IO ()
checkHelperVector prefix path (password, entropy, rootHex) = do
  expectedAccount <- require $ Private.withKeyHex rootHex $ \root ->
    Private.withDerived root (Path.accountIndices prefix) Private.publicKey
  expected <- require $ Private.withKeyHex rootHex $ \root ->
    Private.withDerived root (Path.toIndices path) Private.publicKey
  accountPublic <- require (Bip32.deriveAccountPublicKey password entropy prefix)
  public <- require (Bip32.derivePublicKey password entropy path)
  performGC
  accountPublic @?= expectedAccount
  public @?= expected
  relative <- require (Public.derive accountPublic (Path.relativeIndices path))
  relative @?= public
  Public.fromBytes (Public.toBytes public) @?= Right expected

checkHelperErrors :: IO ()
checkHelperErrors = mapM_ check [0, 1, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33, 64]
  where
    prefix = Path.standardAccountPath minBound
    path = Path.derivationPath prefix Path.externalRole minBound
    check size = do
      let entropy = ByteString.replicate size 0
          expected = Left (InvalidBip39EntropyLength size)
      Bip32.deriveAccountPublicKey "password" entropy prefix >>= (@?= expected)
      Bip32.derivePublicKey "password" entropy path >>= (@?= expected)

propBounded :: Property
propBounded = property $ do
  value <- forAll (Gen.integral (Range.linear (-2147483648) 4294967295))
  let lower = minBound :: Path.Index
      upper = maxBound :: Path.Index
      valid = value >= toInteger (Path.indexValue lower) && value <= toInteger (Path.indexValue upper)
  Path.indexValue lower === 0
  Path.indexValue upper === 2147483647
  Path.mkIndex 0 === Right lower
  Path.mkIndex 2147483647 === Right upper
  case Path.mkIndex value of
    Left err -> do
      assert (not valid)
      err === InvalidDerivationIndex value
    Right component -> do
      assert valid
      assert (lower <= component && component <= upper)
      toInteger (Path.indexValue component) === value

propEncoding :: Property
propEncoding = property $ do
  values <- forAll (Gen.list (Range.singleton 5) (Gen.integral (Range.linear 0 2147483647)))
  components <- evalEither (traverse Path.mkIndex values)
  case components of
    [purpose, coin, account, role, index] -> do
      let prefix = Path.accountPath purpose coin account
          path = Path.derivationPath prefix role index
      map Path.indexValue [Path.purpose prefix, Path.coinType prefix, Path.account prefix, Path.role path, Path.index path]
        === map fromInteger values
      Path.accountPrefix path === prefix
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
