/**
 * \file cometa_error_codes_test.c
 *
 * \author angel.castillo
 * \date   Nov 04, 2026
 *
 * Copyright 2026 Biglup Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* INCLUDES ******************************************************************/

#include <cardano/error.h>

#include <limits.h>
#include <stddef.h>

/* STRUCTURES ****************************************************************/

/**
 * \brief One native-header status name and numeric value used only by the test suite.
 */
typedef struct cometa_test_error_code_t
{
    /**
     * \brief Symbol name used in assertion diagnostics.
     */
    const char* name;

    /**
     * \brief Header-defined value converted to the adapter's explicit unsigned status ABI.
     */
    unsigned int value;
} cometa_test_error_code_t;

/* STATIC VARIABLES **********************************************************/

/**
 * \brief Complete status inventory from the pinned cardano-c header, in numeric order.
 *
 * Values are read from the installed header rather than copied numeric literals. This independent
 * test oracle detects drift between native assignments and the copied Haskell status values.
 */
static const cometa_test_error_code_t error_codes[] = {
  { "CARDANO_SUCCESS", CARDANO_SUCCESS },
  { "CARDANO_ERROR_GENERIC", CARDANO_ERROR_GENERIC },
  { "CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE", CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE },
  { "CARDANO_ERROR_POINTER_IS_NULL", CARDANO_ERROR_POINTER_IS_NULL },
  { "CARDANO_ERROR_MEMORY_ALLOCATION_FAILED", CARDANO_ERROR_MEMORY_ALLOCATION_FAILED },
  { "CARDANO_ERROR_OUT_OF_BOUNDS_MEMORY_READ", CARDANO_ERROR_OUT_OF_BOUNDS_MEMORY_READ },
  { "CARDANO_ERROR_OUT_OF_BOUNDS_MEMORY_WRITE", CARDANO_ERROR_OUT_OF_BOUNDS_MEMORY_WRITE },
  { "CARDANO_ERROR_INVALID_ARGUMENT", CARDANO_ERROR_INVALID_ARGUMENT },
  { "CARDANO_ERROR_INVALID_URL", CARDANO_ERROR_INVALID_URL },
  { "CARDANO_ERROR_ELEMENT_NOT_FOUND", CARDANO_ERROR_ELEMENT_NOT_FOUND },
  { "CARDANO_ERROR_ENCODING", CARDANO_ERROR_ENCODING },
  { "CARDANO_ERROR_DECODING", CARDANO_ERROR_DECODING },
  { "CARDANO_ERROR_CHECKSUM_MISMATCH", CARDANO_ERROR_CHECKSUM_MISMATCH },
  { "CARDANO_ERROR_INVALID_JSON", CARDANO_ERROR_INVALID_JSON },
  { "CARDANO_ERROR_INTEGER_OVERFLOW", CARDANO_ERROR_INTEGER_OVERFLOW },
  { "CARDANO_ERROR_INTEGER_UNDERFLOW", CARDANO_ERROR_INTEGER_UNDERFLOW },
  { "CARDANO_ERROR_CONVERSION_FAILED", CARDANO_ERROR_CONVERSION_FAILED },
  { "CARDANO_ERROR_INDEX_OUT_OF_BOUNDS", CARDANO_ERROR_INDEX_OUT_OF_BOUNDS },
  { "CARDANO_ERROR_INVALID_CERTIFICATE_TYPE", CARDANO_ERROR_INVALID_CERTIFICATE_TYPE },
  { "CARDANO_ERROR_NOT_IMPLEMENTED", CARDANO_ERROR_NOT_IMPLEMENTED },
  { "CARDANO_ERROR_INVALID_PASSPHRASE", CARDANO_ERROR_INVALID_PASSPHRASE },
  { "CARDANO_ERROR_ILLEGAL_STATE", CARDANO_ERROR_ILLEGAL_STATE },
  { "CARDANO_ERROR_DUPLICATED_KEY", CARDANO_ERROR_DUPLICATED_KEY },
  { "CARDANO_ERROR_JSON_TYPE_MISMATCH", CARDANO_ERROR_JSON_TYPE_MISMATCH },
  { "CARDANO_ERROR_LOSS_OF_PRECISION", CARDANO_ERROR_LOSS_OF_PRECISION },
  { "CARDANO_ERROR_INVALID_MAGIC", CARDANO_ERROR_INVALID_MAGIC },
  { "CARDANO_ERROR_INVALID_CHECKSUM", CARDANO_ERROR_INVALID_CHECKSUM },
  { "CARDANO_ERROR_INVALID_BLAKE2B_HASH_SIZE", CARDANO_ERROR_INVALID_BLAKE2B_HASH_SIZE },
  { "CARDANO_ERROR_INVALID_ED25519_SIGNATURE_SIZE", CARDANO_ERROR_INVALID_ED25519_SIGNATURE_SIZE },
  { "CARDANO_ERROR_INVALID_ED25519_PUBLIC_KEY_SIZE", CARDANO_ERROR_INVALID_ED25519_PUBLIC_KEY_SIZE },
  { "CARDANO_ERROR_INVALID_ED25519_PRIVATE_KEY_SIZE", CARDANO_ERROR_INVALID_ED25519_PRIVATE_KEY_SIZE },
  { "CARDANO_ERROR_INVALID_BIP32_PUBLIC_KEY_SIZE", CARDANO_ERROR_INVALID_BIP32_PUBLIC_KEY_SIZE },
  { "CARDANO_ERROR_INVALID_BIP32_PRIVATE_KEY_SIZE", CARDANO_ERROR_INVALID_BIP32_PRIVATE_KEY_SIZE },
  { "CARDANO_ERROR_INVALID_BIP32_DERIVATION_INDEX", CARDANO_ERROR_INVALID_BIP32_DERIVATION_INDEX },
  { "CARDANO_ERROR_UNEXPECTED_CBOR_TYPE", CARDANO_ERROR_UNEXPECTED_CBOR_TYPE },
  { "CARDANO_ERROR_INVALID_CBOR_VALUE", CARDANO_ERROR_INVALID_CBOR_VALUE },
  { "CARDANO_ERROR_INVALID_CBOR_ARRAY_SIZE", CARDANO_ERROR_INVALID_CBOR_ARRAY_SIZE },
  { "CARDANO_ERROR_INVALID_CBOR_MAP_SIZE", CARDANO_ERROR_INVALID_CBOR_MAP_SIZE },
  { "CARDANO_ERROR_DUPLICATED_CBOR_MAP_KEY", CARDANO_ERROR_DUPLICATED_CBOR_MAP_KEY },
  { "CARDANO_ERROR_INVALID_CBOR_MAP_KEY", CARDANO_ERROR_INVALID_CBOR_MAP_KEY },
  { "CARDANO_ERROR_INVALID_ADDRESS_TYPE", CARDANO_ERROR_INVALID_ADDRESS_TYPE },
  { "CARDANO_ERROR_INVALID_ADDRESS_FORMAT", CARDANO_ERROR_INVALID_ADDRESS_FORMAT },
  { "CARDANO_ERROR_INVALID_CREDENTIAL_TYPE", CARDANO_ERROR_INVALID_CREDENTIAL_TYPE },
  { "CARDANO_ERROR_INVALID_PLUTUS_DATA_CONVERSION", CARDANO_ERROR_INVALID_PLUTUS_DATA_CONVERSION },
  { "CARDANO_ERROR_INVALID_DATUM_TYPE", CARDANO_ERROR_INVALID_DATUM_TYPE },
  { "CARDANO_ERROR_INVALID_SCRIPT_LANGUAGE", CARDANO_ERROR_INVALID_SCRIPT_LANGUAGE },
  { "CARDANO_ERROR_INVALID_NATIVE_SCRIPT_TYPE", CARDANO_ERROR_INVALID_NATIVE_SCRIPT_TYPE },
  { "CARDANO_ERROR_INVALID_PLUTUS_COST_MODEL", CARDANO_ERROR_INVALID_PLUTUS_COST_MODEL },
  { "CARDANO_ERROR_INVALID_PROCEDURE_PROPOSAL_TYPE", CARDANO_ERROR_INVALID_PROCEDURE_PROPOSAL_TYPE },
  { "CARDANO_ERROR_INVALID_METADATUM_CONVERSION", CARDANO_ERROR_INVALID_METADATUM_CONVERSION },
  { "CARDANO_ERROR_INVALID_METADATUM_TEXT_STRING_SIZE", CARDANO_ERROR_INVALID_METADATUM_TEXT_STRING_SIZE },
  { "CARDANO_ERROR_INVALID_METADATUM_BOUNDED_BYTES_SIZE", CARDANO_ERROR_INVALID_METADATUM_BOUNDED_BYTES_SIZE },
  { "CARDANO_ERROR_INVALID_HTTP_REQUEST", CARDANO_ERROR_INVALID_HTTP_REQUEST },
  { "CARDANO_ERROR_BALANCE_INSUFFICIENT", CARDANO_ERROR_BALANCE_INSUFFICIENT },
  { "CARDANO_ERROR_UTXO_NOT_FRAGMENTED_ENOUGH", CARDANO_ERROR_UTXO_NOT_FRAGMENTED_ENOUGH },
  { "CARDANO_ERROR_UTXO_FULLY_DEPLETED", CARDANO_ERROR_UTXO_FULLY_DEPLETED },
  { "CARDANO_ERROR_MAXIMUM_INPUT_COUNT_EXCEEDED", CARDANO_ERROR_MAXIMUM_INPUT_COUNT_EXCEEDED },
  { "CARDANO_ERROR_UNBALANCED_SUB_TRANSACTIONS", CARDANO_ERROR_UNBALANCED_SUB_TRANSACTIONS },
  { "CARDANO_ERROR_NOT_ALLOWED_SUPPLEMENTAL_DATUMS", CARDANO_ERROR_NOT_ALLOWED_SUPPLEMENTAL_DATUMS },
  { "CARDANO_ERROR_MISSING_REDEEMER", CARDANO_ERROR_MISSING_REDEEMER },
  { "CARDANO_ERROR_SCRIPT_EVALUATION_FAILURE", CARDANO_ERROR_SCRIPT_EVALUATION_FAILURE }
};

/* DEFINITIONS ***************************************************************/

/**
 * \brief Retrieves the number of native status constants covered by this pinned inventory.
 *
 * \returns The number of entries in the status oracle.
 */
size_t
cometa_test_error_code_count(void)
{
  return sizeof(error_codes) / sizeof(error_codes[0]);
}

/**
 * \brief Retrieves a status constant's native symbol name.
 *
 * \param[in] index Zero-based index into the status inventory.
 *
 * \returns A borrowed static symbol name, or an empty string if the index is out of bounds.
 */
const char*
cometa_test_error_code_name(size_t index)
{
  return index < cometa_test_error_code_count() ? error_codes[index].name : "";
}

/**
 * \brief Retrieves a status constant's value from the installed native header.
 *
 * \param[in] index Zero-based index into the status inventory.
 *
 * \returns The unsigned status value, or zero if the index is out of bounds.
 */
unsigned int
cometa_test_error_code_value(size_t index)
{
  return index < cometa_test_error_code_count() ? error_codes[index].value : 0U;
}

/**
 * \brief Retrieves the size of the C adapter's explicit unsigned status type.
 *
 * \returns The size of unsigned int in bytes. Native enum layout does not cross the adapter ABI.
 */
size_t
cometa_test_status_size(void)
{
  return sizeof(unsigned int);
}

/**
 * \brief Retrieves the largest value representable by the explicit unsigned status ABI.
 *
 * \returns UINT_MAX, allowing the Haskell test to detect width or signedness mismatches.
 */
unsigned int
cometa_test_status_max(void)
{
  return UINT_MAX;
}

/**
 * \brief Exercises status conversion through the native enum and the explicit unsigned ABI.
 *
 * \param[in] value A known native status value from the pinned header.
 *
 * \returns The value after conversion to cardano_error_t and back to unsigned int.
 */
unsigned int
cometa_test_status_roundtrip(unsigned int value)
{
  cardano_error_t native = (cardano_error_t)value;

  return (unsigned int)native;
}
