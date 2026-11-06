/**
 * \file contextual_transaction_oracle.c
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

#include <cardano/cardano.h>

/** Independent direct public-API oracle. Borrow inputs, release all parsed
 * owners before returning, initialize the output on every path. */
unsigned int
cometa_test_contextual_index(const unsigned char* bytes, size_t size, unsigned int operation, const unsigned char* key, size_t key_size, uint64_t argument, uint64_t* index)
{
  cardano_cbor_reader_t*    reader      = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_reader_t*    key_reader  = NULL;
  cardano_transaction_t*    transaction = NULL;
  cardano_reward_address_t* reward      = NULL;
  cardano_voter_t*          voter       = NULL;
  cardano_certificate_t*    certificate = NULL;
  cardano_error_t           result      = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  *index                                = UINT64_MAX;
  if (reader == NULL)
  {
    goto cleanup;
  }
  result = cardano_transaction_from_cbor(reader, &transaction);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  if (operation == 0U)
  {
    result = cardano_reward_address_from_bytes(key, key_size, &reward);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_transaction_find_withdrawal_index(transaction, reward, index);
    }
  }
  else if (operation == 2U)
  {
    result = key_size == 1U ? cardano_transaction_find_redeemer_index(transaction, (cardano_redeemer_tag_t)key[0], argument, index) : CARDANO_ERROR_INVALID_ARGUMENT;
  }
  else
  {
    key_reader = cardano_cbor_reader_new(key, key_size);
    if (key_reader == NULL)
    {
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
      goto cleanup;
    }
    if (operation == 1U)
    {
      result = cardano_voter_from_cbor(key_reader, &voter);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_transaction_find_vote_index(transaction, voter, index);
      }
    }
    else
    {
      result = cardano_certificate_from_cbor(key_reader, &certificate);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_transaction_find_certificate_index(transaction, certificate, index);
      }
    }
  }
cleanup:
  cardano_certificate_unref(&certificate);
  cardano_voter_unref(&voter);
  cardano_reward_address_unref(&reward);
  cardano_transaction_unref(&transaction);
  cardano_cbor_reader_unref(&key_reader);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
