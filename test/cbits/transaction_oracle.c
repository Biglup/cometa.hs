/* Copyright 2026 Biglup Labs
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
#include <stdint.h>
#include <string.h>

/* This test oracle calls native APIs directly, independently of the production
 * adapter. Every getter below transfers a reference; cleanup releases all of
 * them, including partially produced results. hash_out has 32 bytes and counts
 * has six uint64_t slots: vkeys, bootstrap, scripts, datums, redeemers, verified
 * vkeys. Input storage is borrowed only until this synchronous call returns. */
unsigned int
cometa_test_transaction_oracle(const unsigned char* bytes, size_t size, uint64_t* fee, unsigned char* hash_out, uint64_t* counts)
{
  cardano_cbor_reader_t*           reader    = cardano_cbor_reader_new(bytes, size);
  cardano_transaction_t*           tx        = NULL;
  cardano_transaction_body_t*      body      = NULL;
  cardano_blake2b_hash_t*          hash      = NULL;
  cardano_witness_set_t*           witnesses = NULL;
  cardano_vkey_witness_set_t*      vkeys     = NULL;
  cardano_bootstrap_witness_set_t* bootstrap = NULL;
  cardano_native_script_set_t*     scripts   = NULL;
  cardano_plutus_data_set_t*       datums    = NULL;
  cardano_redeemer_list_t*         redeemers = NULL;
  cardano_error_t                  result    = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  memset(counts, 0, 6U * sizeof(uint64_t));
  if (reader == NULL)
  {
    goto cleanup;
  }
  result = cardano_transaction_from_cbor(reader, &tx);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  body      = cardano_transaction_get_body(tx);
  hash      = cardano_transaction_body_get_hash(body);
  witnesses = cardano_transaction_get_witness_set(tx);
  if ((body == NULL) || (hash == NULL) || (witnesses == NULL) || (cardano_blake2b_hash_get_bytes_size(hash) != 32U))
  {
    result = CARDANO_ERROR_GENERIC;
    goto cleanup;
  }
  *fee = cardano_transaction_body_get_fee(body);
  memcpy(hash_out, cardano_blake2b_hash_get_data(hash), 32U);
  vkeys     = cardano_witness_set_get_vkeys(witnesses);
  bootstrap = cardano_witness_set_get_bootstrap(witnesses);
  scripts   = cardano_witness_set_get_native_scripts(witnesses);
  datums    = cardano_witness_set_get_plutus_data(witnesses);
  redeemers = cardano_witness_set_get_redeemers(witnesses);
  counts[0] = cardano_vkey_witness_set_get_length(vkeys);
  counts[1] = cardano_bootstrap_witness_set_get_length(bootstrap);
  counts[2] = cardano_native_script_set_get_length(scripts);
  counts[3] = cardano_plutus_data_set_get_length(datums);
  counts[4] = cardano_redeemer_list_get_length(redeemers);
  for (size_t i = 0U; i < counts[0]; ++i)
  {
    cardano_vkey_witness_t* witness = NULL;
    result                          = cardano_vkey_witness_set_get(vkeys, i, &witness);
    if (result != CARDANO_SUCCESS)
    {
      cardano_vkey_witness_unref(&witness);
      goto cleanup;
    }
    cardano_ed25519_public_key_t* key       = cardano_vkey_witness_get_vkey(witness);
    cardano_ed25519_signature_t*  signature = cardano_vkey_witness_get_signature(witness);
    if (cardano_ed25519_public_verify(key, signature, hash_out, 32U))
    {
      ++counts[5];
    }
    cardano_ed25519_signature_unref(&signature);
    cardano_ed25519_public_key_unref(&key);
    cardano_vkey_witness_unref(&witness);
  }
cleanup:
  cardano_redeemer_list_unref(&redeemers);
  cardano_plutus_data_set_unref(&datums);
  cardano_native_script_set_unref(&scripts);
  cardano_bootstrap_witness_set_unref(&bootstrap);
  cardano_vkey_witness_set_unref(&vkeys);
  cardano_witness_set_unref(&witnesses);
  cardano_blake2b_hash_unref(&hash);
  cardano_transaction_body_unref(&body);
  cardano_transaction_unref(&tx);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
