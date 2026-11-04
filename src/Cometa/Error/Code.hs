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

-- | Named cardano-c status codes, including success. Unknown numeric codes are
-- preserved exactly for logging and interchange. A code can be named even when
-- this package does not expose operations from the corresponding domain.
--
-- @
-- import qualified Cometa.Error.Code as Code
--
-- main :: IO ()
-- main = print (Code.fromNumber (Code.toNumber Code.InvalidArgument) == Code.InvalidArgument)
-- @
module Cometa.Error.Code
  ( -- * Status codes
    ErrorCode
      ( Success,
        GenericFailure,
        InsufficientBufferSize,
        NullPointer,
        MemoryAllocationFailed,
        OutOfBoundsMemoryRead,
        OutOfBoundsMemoryWrite,
        InvalidArgument,
        InvalidUrl,
        ElementNotFound,
        EncodingFailure,
        DecodingFailure,
        ChecksumMismatch,
        InvalidJson,
        IntegerOverflow,
        IntegerUnderflow,
        ConversionFailed,
        IndexOutOfBounds,
        InvalidCertificateType,
        NotImplemented,
        InvalidPassphrase,
        IllegalState,
        DuplicateKey,
        JsonTypeMismatch,
        LossOfPrecision,
        InvalidMagic,
        InvalidChecksum,
        InvalidBlake2bHashSize,
        InvalidEd25519SignatureSize,
        InvalidEd25519PublicKeySize,
        InvalidEd25519PrivateKeySize,
        InvalidBip32PublicKeySize,
        InvalidBip32PrivateKeySize,
        InvalidBip32DerivationIndex,
        UnexpectedCborType,
        InvalidCborValue,
        InvalidCborArraySize,
        InvalidCborMapSize,
        DuplicateCborMapKey,
        InvalidCborMapKey,
        InvalidAddressType,
        InvalidAddressFormat,
        InvalidCredentialType,
        InvalidPlutusDataConversion,
        InvalidDatumType,
        InvalidScriptLanguage,
        InvalidNativeScriptType,
        InvalidPlutusCostModel,
        InvalidProposalProcedureType,
        InvalidMetadatumConversion,
        InvalidMetadatumTextStringSize,
        InvalidMetadatumBoundedBytesSize,
        InvalidHttpRequest,
        InsufficientBalance,
        UtxoNotFragmentedEnough,
        UtxoFullyDepleted,
        MaximumInputCountExceeded,
        UnbalancedSubTransactions,
        DisallowedSupplementalDatums,
        MissingRedeemer,
        ScriptEvaluationFailure
      ),

    -- * Numeric conversion
    fromNumber,
    toNumber,

    -- * Inspection
    isKnown,
    knownCodes,
  )
where

-- TYPES ----------------------------------------------------------------------

-- | A native status code. 'Success' represents a successful operation; all other
-- named constructors represent failures. Use 'fromNumber' to construct a code
-- from any integer, and 'isKnown' to distinguish named and unrecognized codes.
-- Equality distinguishes exact numeric codes. 'Show' is diagnostic only.
data ErrorCode
  = -- | Successful operation.
    Success
  | -- | Generic error.
    GenericFailure
  | -- | Insufficient buffer size.
    InsufficientBufferSize
  | -- | Operation over a null pointer.
    NullPointer
  | -- | Memory could not be allocated.
    MemoryAllocationFailed
  | -- | Out of bounds memory read.
    OutOfBoundsMemoryRead
  | -- | Out of bounds memory write.
    OutOfBoundsMemoryWrite
  | -- | Invalid argument.
    InvalidArgument
  | -- | Invalid URL.
    InvalidUrl
  | -- | Element not found.
    ElementNotFound
  | -- | Encoding failure.
    EncodingFailure
  | -- | Decoding failure.
    DecodingFailure
  | -- | Invalid checksum.
    ChecksumMismatch
  | -- | Invalid JSON.
    InvalidJson
  | -- | An integer exceeds its upper bound.
    IntegerOverflow
  | -- | An integer is below its lower bound.
    IntegerUnderflow
  | -- | Conversion error.
    ConversionFailed
  | -- | Index out of bounds.
    IndexOutOfBounds
  | -- | Invalid certificate type.
    InvalidCertificateType
  | -- | The operation is not implemented.
    NotImplemented
  | -- | The passphrase is invalid.
    InvalidPassphrase
  | -- | The state of the object is illegal.
    IllegalState
  | -- | The element is already present.
    DuplicateKey
  | -- | The JSON type is unexpected.
    JsonTypeMismatch
  | -- | The serialization or deserialization process resulted in a loss of precision.
    LossOfPrecision
  | -- | The magic number is invalid.
    InvalidMagic
  | -- | The checksum is invalid.
    InvalidChecksum
  | -- | The hash size is invalid.
    InvalidBlake2bHashSize
  | -- | The Ed25519 signature size is invalid.
    InvalidEd25519SignatureSize
  | -- | The Ed25519 public key size is invalid.
    InvalidEd25519PublicKeySize
  | -- | The Ed25519 private key size is invalid.
    InvalidEd25519PrivateKeySize
  | -- | The BIP32 public key size is invalid.
    InvalidBip32PublicKeySize
  | -- | The BIP32 private key size is invalid.
    InvalidBip32PrivateKeySize
  | -- | The BIP32 derivation index is invalid.
    InvalidBip32DerivationIndex
  | -- | The CBOR type is unexpected.
    UnexpectedCborType
  | -- | The CBOR type is expected, but its value is invalid or out of range.
    InvalidCborValue
  | -- | The CBOR array size is invalid.
    InvalidCborArraySize
  | -- | The CBOR map size is invalid.
    InvalidCborMapSize
  | -- | The CBOR map key is duplicated.
    DuplicateCborMapKey
  | -- | The CBOR map key is invalid.
    InvalidCborMapKey
  | -- | The address type is invalid.
    InvalidAddressType
  | -- | The address format is invalid.
    InvalidAddressFormat
  | -- | The credential type is invalid.
    InvalidCredentialType
  | -- | The Plutus data conversion is invalid.
    InvalidPlutusDataConversion
  | -- | The Plutus datum type is invalid.
    InvalidDatumType
  | -- | The script language is invalid.
    InvalidScriptLanguage
  | -- | The native script type is invalid.
    InvalidNativeScriptType
  | -- | The Plutus cost model is invalid.
    InvalidPlutusCostModel
  | -- | The governance action type is invalid.
    InvalidProposalProcedureType
  | -- | The metadatum conversion is invalid.
    InvalidMetadatumConversion
  | -- | The metadatum text string size is invalid.
    InvalidMetadatumTextStringSize
  | -- | The metadatum bounded byte string size is invalid.
    InvalidMetadatumBoundedBytesSize
  | -- | The HTTP request is invalid.
    InvalidHttpRequest
  | -- | Available UTxO value is less than the requested output value.
    InsufficientBalance
  | -- | The selection algorithm requires more UTxO entries to cover the outputs.
    UtxoNotFragmentedEnough
  | -- | Selection exhausted the available UTxO entries before covering all outputs.
    UtxoFullyDepleted
  | -- | Progress would exceed the selection algorithm's maximum input count.
    MaximumInputCountExceeded
  | -- | Subtransactions do not conserve value as required by the batch.
    UnbalancedSubTransactions
  | -- | The top-level transaction carries a witness datum disallowed for its batch.
    DisallowedSupplementalDatums
  | -- | A Plutus script purpose in the transaction or its subtransactions lacks a redeemer.
    MissingRedeemer
  | -- | The transaction script evaluation failed.
    ScriptEvaluationFailure
  | UnknownCode !Integer
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Interpret a numeric status code. Every integer is accepted, including
-- negative values and values outside machine integer ranges, without truncation.
-- A recognized number becomes its named constructor; all others remain unknown.
--
-- @toNumber (fromNumber number) == number@
fromNumber :: Integer -> ErrorCode
fromNumber number = case lookup number [(toNumber code, code) | code <- knownCodes] of
  Just code -> code
  Nothing -> UnknownCode number

-- | Return the exact numeric code. No conversion to a bounded machine integer
-- occurs. This is the inverse of 'fromNumber' on all 'ErrorCode' values.
toNumber :: ErrorCode -> Integer
toNumber code = case code of
  Success -> 0
  GenericFailure -> 1
  InsufficientBufferSize -> 2
  NullPointer -> 3
  MemoryAllocationFailed -> 4
  OutOfBoundsMemoryRead -> 5
  OutOfBoundsMemoryWrite -> 6
  InvalidArgument -> 7
  InvalidUrl -> 8
  ElementNotFound -> 9
  EncodingFailure -> 10
  DecodingFailure -> 11
  ChecksumMismatch -> 12
  InvalidJson -> 13
  IntegerOverflow -> 14
  IntegerUnderflow -> 15
  ConversionFailed -> 16
  IndexOutOfBounds -> 17
  InvalidCertificateType -> 18
  NotImplemented -> 19
  InvalidPassphrase -> 20
  IllegalState -> 21
  DuplicateKey -> 22
  JsonTypeMismatch -> 23
  LossOfPrecision -> 100
  InvalidMagic -> 101
  InvalidChecksum -> 102
  InvalidBlake2bHashSize -> 200
  InvalidEd25519SignatureSize -> 201
  InvalidEd25519PublicKeySize -> 202
  InvalidEd25519PrivateKeySize -> 203
  InvalidBip32PublicKeySize -> 204
  InvalidBip32PrivateKeySize -> 205
  InvalidBip32DerivationIndex -> 206
  UnexpectedCborType -> 300
  InvalidCborValue -> 301
  InvalidCborArraySize -> 302
  InvalidCborMapSize -> 303
  DuplicateCborMapKey -> 304
  InvalidCborMapKey -> 305
  InvalidAddressType -> 400
  InvalidAddressFormat -> 401
  InvalidCredentialType -> 500
  InvalidPlutusDataConversion -> 600
  InvalidDatumType -> 601
  InvalidScriptLanguage -> 700
  InvalidNativeScriptType -> 701
  InvalidPlutusCostModel -> 702
  InvalidProposalProcedureType -> 800
  InvalidMetadatumConversion -> 900
  InvalidMetadatumTextStringSize -> 901
  InvalidMetadatumBoundedBytesSize -> 902
  InvalidHttpRequest -> 1000
  InsufficientBalance -> 1100
  UtxoNotFragmentedEnough -> 1101
  UtxoFullyDepleted -> 1102
  MaximumInputCountExceeded -> 1103
  UnbalancedSubTransactions -> 1104
  DisallowedSupplementalDatums -> 1105
  MissingRedeemer -> 1106
  ScriptEvaluationFailure -> 1200
  UnknownCode number -> number

-- | Whether a code has a name in this build of the package.
-- This does not indicate success: use equality with 'Success' for that purpose.
isKnown :: ErrorCode -> Bool
isKnown (UnknownCode _) = False
isKnown _ = True

-- | Every named code, including 'Success', once each, in numeric order.
-- Unknown numeric codes are excluded. Values have gaps; do not infer a code
-- by adding to or subtracting from another code.
knownCodes :: [ErrorCode]
knownCodes =
  [ Success,
    GenericFailure,
    InsufficientBufferSize,
    NullPointer,
    MemoryAllocationFailed,
    OutOfBoundsMemoryRead,
    OutOfBoundsMemoryWrite,
    InvalidArgument,
    InvalidUrl,
    ElementNotFound,
    EncodingFailure,
    DecodingFailure,
    ChecksumMismatch,
    InvalidJson,
    IntegerOverflow,
    IntegerUnderflow,
    ConversionFailed,
    IndexOutOfBounds,
    InvalidCertificateType,
    NotImplemented,
    InvalidPassphrase,
    IllegalState,
    DuplicateKey,
    JsonTypeMismatch,
    LossOfPrecision,
    InvalidMagic,
    InvalidChecksum,
    InvalidBlake2bHashSize,
    InvalidEd25519SignatureSize,
    InvalidEd25519PublicKeySize,
    InvalidEd25519PrivateKeySize,
    InvalidBip32PublicKeySize,
    InvalidBip32PrivateKeySize,
    InvalidBip32DerivationIndex,
    UnexpectedCborType,
    InvalidCborValue,
    InvalidCborArraySize,
    InvalidCborMapSize,
    DuplicateCborMapKey,
    InvalidCborMapKey,
    InvalidAddressType,
    InvalidAddressFormat,
    InvalidCredentialType,
    InvalidPlutusDataConversion,
    InvalidDatumType,
    InvalidScriptLanguage,
    InvalidNativeScriptType,
    InvalidPlutusCostModel,
    InvalidProposalProcedureType,
    InvalidMetadatumConversion,
    InvalidMetadatumTextStringSize,
    InvalidMetadatumBoundedBytesSize,
    InvalidHttpRequest,
    InsufficientBalance,
    UtxoNotFragmentedEnough,
    UtxoFullyDepleted,
    MaximumInputCountExceeded,
    UnbalancedSubTransactions,
    DisallowedSupplementalDatums,
    MissingRedeemer,
    ScriptEvaluationFailure
  ]
