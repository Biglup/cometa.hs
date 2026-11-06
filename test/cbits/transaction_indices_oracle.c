/**
 * \file transaction_indices_oracle.c
 *
 * Copyright 2026 Biglup Labs
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* INCLUDES ******************************************************************/

#include <cardano/cardano.h>

/* DEFINITIONS ***************************************************************/

/** \brief Query public native index APIs independently of Haskell inspection.
 * Input buffers are borrowed. The output is initialized to UINT64_MAX on every
 * call; all temporary parsed owners are released on success and failure.
 */
unsigned int
cometa_test_transaction_index(const unsigned char* bytes, size_t size, unsigned int operation, const unsigned char* key, size_t key_size, uint64_t argument, uint64_t* index)
{
  cardano_cbor_reader_t*  reader      = cardano_cbor_reader_new(bytes, size);
  cardano_transaction_t*  transaction = NULL;
  cardano_blake2b_hash_t* hash        = NULL;
  cardano_address_t*      address     = NULL;
  cardano_error_t         result      = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  *index                              = UINT64_MAX;
  if (reader == NULL)
  {
    goto cleanup;
  }
  result = cardano_transaction_from_cbor(reader, &transaction);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  if (operation == 2U)
  {
    result = cardano_address_from_bytes(key, key_size, &address);
  }
  else
  {
    result = cardano_blake2b_hash_from_bytes(key, key_size, &hash);
  }
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  switch (operation)
  {
    case 0U:
      result = cardano_transaction_find_input_index(transaction, hash, argument, index);
      break;
    case 1U:
      result = cardano_transaction_find_reference_input_index(transaction, hash, argument, index);
      break;
    case 2U:
      result = cardano_transaction_find_output_index(transaction, address, argument, index);
      break;
    case 3U:
      result = cardano_transaction_find_mint_policy_index(transaction, hash, index);
      break;
    default:
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      break;
  }
cleanup:
  cardano_address_unref(&address);
  cardano_blake2b_hash_unref(&hash);
  cardano_transaction_unref(&transaction);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
