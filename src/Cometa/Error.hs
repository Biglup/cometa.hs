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

-- | Validation and operation failures. Match constructors and status codes to
-- handle errors; diagnostic messages are intended for people.
--
-- @
-- import qualified Cometa.Crypto.Blake2b as Blake2b
-- import qualified Data.ByteString as ByteString
--
-- main :: IO ()
-- main = case Blake2b.fromBytes ByteString.empty of
--   Left err -> print err
--   Right digest -> print digest
-- @
module Cometa.Error
  ( Error (..),
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error.Code (ErrorCode)
import Data.Text (Text)
import Data.Word (Word32, Word64, Word8)

-- TYPES ----------------------------------------------------------------------

-- | Expected failures returned by Cometa operations. Equality compares every
-- payload, including diagnostic text. 'Show' is diagnostic output.
data Error
  = -- | An operation failed with a cardano-c status code. Unknown numeric codes
    -- remain available through @toNumber@ in "Cometa.Error.Code".
    NativeError
      -- | Operation name, such as @blake2b.compute@; excludes user input.
      !Text
      -- | Exact status code, with a name when recognized.
      !ErrorCode
      -- | Diagnostic message; do not parse it to determine the failure.
      !Text
  | -- | A transaction-building request has invalid context or inconsistent inputs.
    InvalidBuildingRequest !Text
  | -- | Transaction requirements conflict or cannot form a valid build request.
    InvalidTransactionPlan !Text
  | -- | A slot configuration or conversion is outside its supported time range.
    InvalidSlotConfig !Text
  | -- | The requested BLAKE2b digest length is outside 16 through 64 bytes.
    InvalidHashLength
      -- | Requested digest length in bytes.
      !Int
  | -- | The digest byte sequence is empty.
    EmptyHash
  | -- | Hexadecimal input is empty, has an odd number of digits, or contains
    -- characters other than ASCII hexadecimal digits. Both cases are accepted.
    InvalidHex
  | -- | An Ed25519 signing-key operation used a handle that has been closed.
    SigningKeyClosed
  | -- | An Ed25519 signing-key input has the wrong byte length for its format.
    InvalidEd25519SigningKeyLength
      -- | Expected byte length: 32 for normal keys, or 64 for extended keys.
      !Int
      -- | Actual input byte length.
      !Int
  | -- | A software key handler has closed.
    KeyHandlerClosed
  | -- | A software key handler already has an active operation.
    KeyHandlerBusy
  | -- | A software handler password is outside 1 through 128 bytes.
    InvalidKeyHandlerPasswordLength !Int
  | -- | Software storage framing, type or secret length is invalid.
    InvalidKeyHandlerStorage
  | -- | An Ed25519 public key does not contain exactly 32 bytes.
    InvalidEd25519PublicKeyLength
      -- | Actual encoded byte length.
      !Int
  | -- | An Ed25519 signature does not contain exactly 64 bytes.
    InvalidEd25519SignatureLength
      -- | Actual encoded byte length.
      !Int
  | -- | A BIP32 private-key handle has closed.
    Bip32PrivateKeyClosed
  | -- | A BIP32 private key must contain exactly 96 bytes.
    InvalidBip32PrivateKeyLength
      -- | Actual byte count.
      !Int
  | -- | A BIP32 public key must contain exactly 64 bytes.
    InvalidBip32PublicKeyLength
      -- | Actual byte count.
      !Int
  | -- | BIP39 entropy must contain 16, 20, 24, 28 or 32 bytes.
    InvalidBip39EntropyLength
      -- | Actual byte count.
      !Int
  | -- | A mnemonic requires 12, 15, 18, 21 or 24 words.
    InvalidBip39WordCount
      -- | Actual number of words.
      !Int
  | -- | A mnemonic word is empty or contains characters outside lowercase ASCII.
    InvalidBip39Word
      -- | One-based word position; excludes the word itself.
      !Int
  | -- | At least one word is absent from the English BIP39 dictionary.
    UnknownBip39Word
  | -- | The mnemonic checksum does not agree with its entropy.
    InvalidBip39Checksum
  | -- | PBKDF2 requires a nonempty salt.
    EmptyPbkdf2Salt
  | -- | PBKDF2 iteration count is outside 1 through 4294967295 inclusive.
    InvalidPbkdf2Iterations
      -- | Requested iteration count.
      !Integer
  | -- | PBKDF2 output byte count is outside its documented bounds.
    InvalidPbkdf2OutputLength
      -- | Requested output byte count.
      !Integer
  | -- | EMIP3 plaintext exceeds its documented size bounds.
    InvalidEmip3PlaintextLength
      -- | Actual plaintext byte count.
      !Int
  | -- | EMIP3 envelope is outside its documented size bounds.
    InvalidEmip3EnvelopeLength
      -- | Actual encoded byte count.
      !Int
  | -- | An unencoded derivation component is outside 0 through 2147483647.
    InvalidDerivationIndex
      -- | Exact requested component number.
      !Integer
  | -- | Public derivation requires soft indices below 2^31.
    HardenedPublicDerivation
      -- | First hardened encoded index encountered.
      !Word32
  | -- | A CBOR integer is outside the supported primitive range, from
    -- @-2^64@ through @2^64 - 1@ inclusive. Tagged bignums are not encoded here.
    InvalidCborInteger
      -- | Requested integer value.
      !Integer
  | -- | A decoded CBOR text string contains invalid UTF-8.
    InvalidCborUtf8
  | -- | A native-asset name exceeds 32 bytes.
    InvalidAssetNameLength !Int
  | -- | Asset-name CBOR is malformed or does not contain a name of 0 through 32 bytes.
    InvalidAssetNameCbor !Text
  | -- | A native-asset identity encoding does not contain 28 through 60 bytes.
    InvalidAssetIdLength !Int
  | -- | A native-asset policy identifier does not contain exactly 28 bytes.
    InvalidPolicyIdLength !Int
  | -- | A credential hash does not contain exactly 28 bytes.
    InvalidCredentialHashLength !Int
  | -- | A credential CBOR item has invalid syntax, shape or kind.
    InvalidCredentialCbor !Text
  | -- | A digest CBOR item has invalid syntax or is not one byte string.
    InvalidHashCbor !Text
  | -- | A Shelley network tag is outside 0 through 15 inclusive.
    InvalidNetworkId !Integer
  | -- | The four-bit header selects an address form unsupported by the chosen
    -- payment-address or reward-account decoder.
    UnsupportedAddressType !Word8
  | -- | Address bytes are empty or have an incorrect exact length.
    InvalidShelleyAddress
  | -- | Address text is malformed, mixed-case, has an invalid checksum or
    -- bit padding, or has a prefix inconsistent with its network/address form.
    InvalidShelleyAddressText
  | -- | Plutus data CBOR is malformed or contains unsupported data forms.
    InvalidPlutusDataCbor !Text
  | -- | A metadata integer is outside -2^64 through 2^64 - 1 inclusive.
    InvalidMetadataInteger !Integer
  | -- | A metadata byte string exceeds 64 bytes.
    InvalidMetadataBytesLength !Int
  | -- | A metadata text string exceeds 64 UTF-8 bytes.
    InvalidMetadataTextLength !Int
  | -- | Metadata CBOR is malformed or violates metadata bounds.
    InvalidMetadataCbor !Text
  | -- | A transaction metadata label occurs more than once.
    DuplicateMetadataLabel !Word64
  | -- | Detailed metadata JSON is malformed or violates metadata bounds.
    InvalidMetadataJson !Text
  | -- | Script CBOR is malformed or has an unsupported script form.
    InvalidScriptCbor !Text
  | -- | Native script construction JSON is malformed or violates script bounds.
    InvalidScriptJson !Text
  | -- | Compiled Plutus script bytes are empty.
    EmptyPlutusScript
  | -- | A protocol fraction has a negative or oversized component, or a zero denominator.
    InvalidProtocolRational !Integer !Integer
  | -- | A unit interval fraction lies outside zero through one inclusive.
    InvalidUnitInterval !Integer !Integer
  | -- | An execution budget component is outside the unsigned 64-bit range.
    InvalidExUnits !Integer !Integer
  | -- | A protocol version exceeds its unsigned major/minor bounds.
    InvalidProtocolVersion !Integer !Integer
  | -- | A protocol value has malformed CBOR or violates its field constraints.
    InvalidProtocolCbor !Text
  | -- | Transaction CBOR is malformed or violates its field constraints.
    InvalidTransactionCbor !Text
  | -- | A transaction output contains an unsupported quantity.
    InvalidTransactionOutputValue !Integer
  | -- | A standalone value has Ada outside 0..2^63-1 or a native quantity outside int64.
    InvalidValueQuantity !Integer
  | -- | Standalone value CBOR is malformed or violates its quantity constraints.
    InvalidValueCbor !Text
  | -- | Governance action identifier text is malformed or has an invalid prefix or payload.
    InvalidGovernanceActionText !Text
  | -- | An action index exceeds the one-byte CIP-129 text representation.
    InvalidGovernanceActionTextIndex !Word64
  | -- | A DRep identifier has an invalid checksum, prefix, header or payload.
    InvalidDRepText !Text
  | -- | A transaction digest does not contain exactly 32 bytes.
    InvalidTransactionHashLength !Int
  | -- | A transaction field violates its domain constraints.
    InvalidTransactionField !Text
  | -- | Witness CBOR is malformed or violates its field constraints.
    InvalidWitnessCbor !Text
  | -- | Redeemer CBOR is malformed or violates its field constraints.
    InvalidRedeemerCbor !Text
  | -- | Auxiliary data CBOR is malformed or violates its field constraints.
    InvalidAuxiliaryDataCbor !Text
  | -- | A bootstrap witness chain code does not contain 32 bytes.
    InvalidBootstrapChainCodeLength !Int
  | -- | Witnesses contain conflicting values for the same identity.
    WitnessConflict !Text
  | -- | Byron address bytes or attributes are malformed or have a bad checksum.
    InvalidByronAddress !Text
  | -- | Byron address text is not a valid Base58 address.
    InvalidByronAddressText
  | -- | A backend rejected an HTTP request. The payload contains the operation
    -- name and HTTP status, without response bodies or credentials.
    ProviderHttpError !Text !Int
  | -- | A backend request could not complete. The payload contains the operation
    -- name and a credential-free description of the transport failure.
    ProviderTransportError !Text !Text
  | -- | A backend response violates the named operation's data contract.
    InvalidProviderResponse !Text
  | -- | A backend configuration is invalid. The diagnostic excludes credentials.
    InvalidProviderConfiguration !Text
  | -- | The requested service capability is not supplied.
    UnsupportedOperation !Text
  | -- | An operation used a resource after its scope ended.
    RuntimeClosed
  | -- | An overlapping operation is already using the same resource.
    RuntimeBusy
  | -- | An injected callback returned a result outside its contract.
    InvalidCallbackResult !Text
  | -- | A parameter snapshot is incomplete or outside supported bounds.
    InvalidParameterSnapshot !Text
  | -- | Coin-selection inputs are inconsistent or outside supported bounds.
    InvalidSelectionRequest !Text
  | -- | A selection violates eligibility, balance or change requirements.
    InvalidSelection !Text
  | -- | An evaluation target or resolved input snapshot is inconsistent.
    InvalidEvaluationRequest !Text
  | -- | Evaluation budgets do not match the transaction's redeemer identities.
    InvalidEvaluationResult !Text
  | -- | Pool CBOR is malformed or violates a field constraint.
    InvalidPoolCbor !Text
  | -- | A pool VRF key hash does not contain 32 bytes.
    InvalidPoolHashLength !Int
  | -- | A pool metadata URL violates its byte-length or NUL constraint.
    InvalidPoolMetadataUrl !Text
  | -- | A pool metadata hash does not contain 32 bytes.
    InvalidPoolMetadataHashLength !Int
  | -- | A relay DNS name violates its byte-length or NUL constraint.
    InvalidPoolDnsName !Text
  | -- | An IP address has an incorrect byte count: expected, then actual.
    InvalidPoolIpLength !Int !Int
  | -- | An IP address text representation is malformed.
    InvalidPoolIpText !Text
  | -- | A BLS key or possession proof has an incorrect byte count.
    InvalidPoolBlsKeyLength
      -- | Actual public-key byte count; 96 is required.
      !Int
      -- | Actual possession-proof byte count; 48 is required.
      !Int
  | -- | A certificate has malformed CBOR or invalid fields.
    InvalidCertificateCbor !Text
  | -- | A governance proposal has malformed CBOR or invalid fields.
    InvalidProposalCbor !Text
  | -- | A reward account occurs more than once in treasury withdrawals.
    DuplicateTreasuryWithdrawal
  | -- | A committee credential occurs more than once.
    DuplicateCommitteeMember
  | -- | A genesis key occurs more than once in a proposed update map.
    DuplicateProtocolUpdate
  | -- | A cost model contains an unsupported number of coefficients.
    InvalidCostModelLength !Int
  | -- | A parameter update has malformed CBOR or invalid fields.
    InvalidProtocolParametersCbor !Text
  | -- | A reference script cost stride is outside 1 through 4294967295 bytes.
    InvalidReferenceScriptCostStride !Integer
  | -- | A nonneutral protocol nonce does not contain exactly 32 bytes.
    InvalidProtocolNonceLength !Int
  | -- | An anchor URL is outside 1 through 128 UTF-8 bytes.
    InvalidAnchorUrlLength !Int
  | -- | An anchor URL contains a NUL character.
    InvalidAnchorUrl
  | -- | An anchor data digest does not contain exactly 32 bytes.
    InvalidAnchorDataHashLength !Int
  | -- | A transaction identifier does not contain exactly 32 bytes.
    InvalidTransactionIdLength !Int
  | -- | Governance CBOR is malformed or violates the selected value's schema.
    InvalidGovernanceCbor !Text
  | -- | A voter/action pair is present more than once.
    DuplicateGovernanceVote
  | -- | An operation reported success but did not produce a valid result.
    NativeContractViolation
      -- | Operation name; excludes user input.
      !Text
  deriving (Eq, Show)
