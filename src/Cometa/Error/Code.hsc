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

{- ORMOLU_DISABLE -}
#include <cardano/error.h>
{- ORMOLU_ENABLE -}

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
{- ORMOLU_DISABLE -}
toNumber code = case code of
  Success -> #{const CARDANO_SUCCESS}
  GenericFailure -> #{const CARDANO_ERROR_GENERIC}
  InsufficientBufferSize -> #{const CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE}
  NullPointer -> #{const CARDANO_ERROR_POINTER_IS_NULL}
  MemoryAllocationFailed -> #{const CARDANO_ERROR_MEMORY_ALLOCATION_FAILED}
  OutOfBoundsMemoryRead -> #{const CARDANO_ERROR_OUT_OF_BOUNDS_MEMORY_READ}
  OutOfBoundsMemoryWrite -> #{const CARDANO_ERROR_OUT_OF_BOUNDS_MEMORY_WRITE}
  InvalidArgument -> #{const CARDANO_ERROR_INVALID_ARGUMENT}
  InvalidUrl -> #{const CARDANO_ERROR_INVALID_URL}
  ElementNotFound -> #{const CARDANO_ERROR_ELEMENT_NOT_FOUND}
  EncodingFailure -> #{const CARDANO_ERROR_ENCODING}
  DecodingFailure -> #{const CARDANO_ERROR_DECODING}
  ChecksumMismatch -> #{const CARDANO_ERROR_CHECKSUM_MISMATCH}
  InvalidJson -> #{const CARDANO_ERROR_INVALID_JSON}
  IntegerOverflow -> #{const CARDANO_ERROR_INTEGER_OVERFLOW}
  IntegerUnderflow -> #{const CARDANO_ERROR_INTEGER_UNDERFLOW}
  ConversionFailed -> #{const CARDANO_ERROR_CONVERSION_FAILED}
  IndexOutOfBounds -> #{const CARDANO_ERROR_INDEX_OUT_OF_BOUNDS}
  InvalidCertificateType -> #{const CARDANO_ERROR_INVALID_CERTIFICATE_TYPE}
  NotImplemented -> #{const CARDANO_ERROR_NOT_IMPLEMENTED}
  InvalidPassphrase -> #{const CARDANO_ERROR_INVALID_PASSPHRASE}
  IllegalState -> #{const CARDANO_ERROR_ILLEGAL_STATE}
  DuplicateKey -> #{const CARDANO_ERROR_DUPLICATED_KEY}
  JsonTypeMismatch -> #{const CARDANO_ERROR_JSON_TYPE_MISMATCH}
  LossOfPrecision -> #{const CARDANO_ERROR_LOSS_OF_PRECISION}
  InvalidMagic -> #{const CARDANO_ERROR_INVALID_MAGIC}
  InvalidChecksum -> #{const CARDANO_ERROR_INVALID_CHECKSUM}
  InvalidBlake2bHashSize -> #{const CARDANO_ERROR_INVALID_BLAKE2B_HASH_SIZE}
  InvalidEd25519SignatureSize -> #{const CARDANO_ERROR_INVALID_ED25519_SIGNATURE_SIZE}
  InvalidEd25519PublicKeySize -> #{const CARDANO_ERROR_INVALID_ED25519_PUBLIC_KEY_SIZE}
  InvalidEd25519PrivateKeySize -> #{const CARDANO_ERROR_INVALID_ED25519_PRIVATE_KEY_SIZE}
  InvalidBip32PublicKeySize -> #{const CARDANO_ERROR_INVALID_BIP32_PUBLIC_KEY_SIZE}
  InvalidBip32PrivateKeySize -> #{const CARDANO_ERROR_INVALID_BIP32_PRIVATE_KEY_SIZE}
  InvalidBip32DerivationIndex -> #{const CARDANO_ERROR_INVALID_BIP32_DERIVATION_INDEX}
  UnexpectedCborType -> #{const CARDANO_ERROR_UNEXPECTED_CBOR_TYPE}
  InvalidCborValue -> #{const CARDANO_ERROR_INVALID_CBOR_VALUE}
  InvalidCborArraySize -> #{const CARDANO_ERROR_INVALID_CBOR_ARRAY_SIZE}
  InvalidCborMapSize -> #{const CARDANO_ERROR_INVALID_CBOR_MAP_SIZE}
  DuplicateCborMapKey -> #{const CARDANO_ERROR_DUPLICATED_CBOR_MAP_KEY}
  InvalidCborMapKey -> #{const CARDANO_ERROR_INVALID_CBOR_MAP_KEY}
  InvalidAddressType -> #{const CARDANO_ERROR_INVALID_ADDRESS_TYPE}
  InvalidAddressFormat -> #{const CARDANO_ERROR_INVALID_ADDRESS_FORMAT}
  InvalidCredentialType -> #{const CARDANO_ERROR_INVALID_CREDENTIAL_TYPE}
  InvalidPlutusDataConversion -> #{const CARDANO_ERROR_INVALID_PLUTUS_DATA_CONVERSION}
  InvalidDatumType -> #{const CARDANO_ERROR_INVALID_DATUM_TYPE}
  InvalidScriptLanguage -> #{const CARDANO_ERROR_INVALID_SCRIPT_LANGUAGE}
  InvalidNativeScriptType -> #{const CARDANO_ERROR_INVALID_NATIVE_SCRIPT_TYPE}
  InvalidPlutusCostModel -> #{const CARDANO_ERROR_INVALID_PLUTUS_COST_MODEL}
  InvalidProposalProcedureType -> #{const CARDANO_ERROR_INVALID_PROCEDURE_PROPOSAL_TYPE}
  InvalidMetadatumConversion -> #{const CARDANO_ERROR_INVALID_METADATUM_CONVERSION}
  InvalidMetadatumTextStringSize -> #{const CARDANO_ERROR_INVALID_METADATUM_TEXT_STRING_SIZE}
  InvalidMetadatumBoundedBytesSize -> #{const CARDANO_ERROR_INVALID_METADATUM_BOUNDED_BYTES_SIZE}
  InvalidHttpRequest -> #{const CARDANO_ERROR_INVALID_HTTP_REQUEST}
  InsufficientBalance -> #{const CARDANO_ERROR_BALANCE_INSUFFICIENT}
  UtxoNotFragmentedEnough -> #{const CARDANO_ERROR_UTXO_NOT_FRAGMENTED_ENOUGH}
  UtxoFullyDepleted -> #{const CARDANO_ERROR_UTXO_FULLY_DEPLETED}
  MaximumInputCountExceeded -> #{const CARDANO_ERROR_MAXIMUM_INPUT_COUNT_EXCEEDED}
  UnbalancedSubTransactions -> #{const CARDANO_ERROR_UNBALANCED_SUB_TRANSACTIONS}
  DisallowedSupplementalDatums -> #{const CARDANO_ERROR_NOT_ALLOWED_SUPPLEMENTAL_DATUMS}
  MissingRedeemer -> #{const CARDANO_ERROR_MISSING_REDEEMER}
  ScriptEvaluationFailure -> #{const CARDANO_ERROR_SCRIPT_EVALUATION_FAILURE}
  UnknownCode number -> number
{- ORMOLU_ENABLE -}

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
