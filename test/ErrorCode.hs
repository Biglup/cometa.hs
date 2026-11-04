module ErrorCode (tests) where

import qualified Cometa.Error.Code as Code
import Data.List (nub)
import Hedgehog (Property, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Native error codes"
    [ testCase "every pinned header code has its expected name and number" $
        mapM_
          ( \(code, number) -> do
              Code.toNumber code @?= number
              Code.fromNumber number @?= code
              Code.isKnown code @?= True
          )
          expectedCodes,
      testCase "known codes are complete, ordered, and distinct" $ do
        Code.knownCodes @?= map fst expectedCodes
        nub (map Code.toNumber Code.knownCodes) @?= map snd expectedCodes,
      testCase "unknown gaps and unbounded integers survive without truncation" $
        mapM_
          ( \number -> do
              let code = Code.fromNumber number
              Code.toNumber code @?= number
              Code.isKnown code @?= False
              Code.fromNumber (Code.toNumber code) @?= code
          )
          [-1, 24, 99, 103, 199, 207, 299, 306, 1201, negate (2 ^ (128 :: Int)), 2 ^ (128 :: Int)],
      testProperty "arbitrary numeric codes round trip" propNumberRoundTrip
    ]

propNumberRoundTrip :: Property
propNumberRoundTrip = property $ do
  number <- forAll (Gen.integral (Range.linear (negate (2 ^ (256 :: Int))) (2 ^ (256 :: Int))))
  let code = Code.fromNumber number
  Code.toNumber code === number
  Code.fromNumber (Code.toNumber code) === code

-- Independent expectations transcribed from cardano/error.h at the pinned
-- revision 8dc0c55f4132fcaa2e7961b6cfbfea96a6d93b5d (Apache-2.0). These do not
-- reuse the implementation's hsc2hs constants: changed native assignments must
-- trigger review rather than silently updating both sides of the test.
expectedCodes :: [(Code.ErrorCode, Integer)]
expectedCodes =
  [ (Code.Success, 0),
    (Code.GenericFailure, 1),
    (Code.InsufficientBufferSize, 2),
    (Code.NullPointer, 3),
    (Code.MemoryAllocationFailed, 4),
    (Code.OutOfBoundsMemoryRead, 5),
    (Code.OutOfBoundsMemoryWrite, 6),
    (Code.InvalidArgument, 7),
    (Code.InvalidUrl, 8),
    (Code.ElementNotFound, 9),
    (Code.EncodingFailure, 10),
    (Code.DecodingFailure, 11),
    (Code.ChecksumMismatch, 12),
    (Code.InvalidJson, 13),
    (Code.IntegerOverflow, 14),
    (Code.IntegerUnderflow, 15),
    (Code.ConversionFailed, 16),
    (Code.IndexOutOfBounds, 17),
    (Code.InvalidCertificateType, 18),
    (Code.NotImplemented, 19),
    (Code.InvalidPassphrase, 20),
    (Code.IllegalState, 21),
    (Code.DuplicateKey, 22),
    (Code.JsonTypeMismatch, 23),
    (Code.LossOfPrecision, 100),
    (Code.InvalidMagic, 101),
    (Code.InvalidChecksum, 102),
    (Code.InvalidBlake2bHashSize, 200),
    (Code.InvalidEd25519SignatureSize, 201),
    (Code.InvalidEd25519PublicKeySize, 202),
    (Code.InvalidEd25519PrivateKeySize, 203),
    (Code.InvalidBip32PublicKeySize, 204),
    (Code.InvalidBip32PrivateKeySize, 205),
    (Code.InvalidBip32DerivationIndex, 206),
    (Code.UnexpectedCborType, 300),
    (Code.InvalidCborValue, 301),
    (Code.InvalidCborArraySize, 302),
    (Code.InvalidCborMapSize, 303),
    (Code.DuplicateCborMapKey, 304),
    (Code.InvalidCborMapKey, 305),
    (Code.InvalidAddressType, 400),
    (Code.InvalidAddressFormat, 401),
    (Code.InvalidCredentialType, 500),
    (Code.InvalidPlutusDataConversion, 600),
    (Code.InvalidDatumType, 601),
    (Code.InvalidScriptLanguage, 700),
    (Code.InvalidNativeScriptType, 701),
    (Code.InvalidPlutusCostModel, 702),
    (Code.InvalidProposalProcedureType, 800),
    (Code.InvalidMetadatumConversion, 900),
    (Code.InvalidMetadatumTextStringSize, 901),
    (Code.InvalidMetadatumBoundedBytesSize, 902),
    (Code.InvalidHttpRequest, 1000),
    (Code.InsufficientBalance, 1100),
    (Code.UtxoNotFragmentedEnough, 1101),
    (Code.UtxoFullyDepleted, 1102),
    (Code.MaximumInputCountExceeded, 1103),
    (Code.UnbalancedSubTransactions, 1104),
    (Code.DisallowedSupplementalDatums, 1105),
    (Code.MissingRedeemer, 1106),
    (Code.ScriptEvaluationFailure, 1200)
  ]
