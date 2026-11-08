/**
 * \file value_oracle.c
 *
 * \author angel.castillo
 * \date   Nov 05, 2026
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

#include <cardano/assets/asset_id.h>
#include <cardano/assets/asset_name.h>
#include <cardano/assets/multi_asset.h>
#include <cardano/cardano.h>
#include <cardano/crypto/blake2b_hash.h>
#include <cardano/transaction_body/value.h>

#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/* The retained multiasset reference is released independently of the value.
 * Missing quantities compare as zero, matching the Haskell semantic bundle. */
static int
matches(cardano_value_t* value, cardano_blake2b_hash_t* policy, cardano_asset_name_t* name, int64_t coin, int64_t amount)
{
  if (value == NULL)
  {
    return 0;
  }

  cardano_multi_asset_t* assets = cardano_value_get_multi_asset(value);
  int64_t                actual = 0;
  cardano_error_t        result = cardano_multi_asset_get(assets, policy, name, &actual);
  int                    agrees = (cardano_value_get_coin(value) == coin) &&
    (((result == CARDANO_SUCCESS) && (actual == amount)) || ((result == CARDANO_ERROR_ELEMENT_NOT_FOUND) && (amount == 0)));

  cardano_multi_asset_unref(&assets);

  return agrees;
}

/* DEFINITIONS ***************************************************************/

/* Test-only borrowed input spans and int64 values. Haskell verifies that every
 * input, sum and difference fits int64 BEFORE casting. This is not checked C
 * arithmetic. Constructors copy/retain inputs; each local obligation is released
 * even on failure, and no mutable native object escapes this function. */
int
cometa_test_value_agreement(
  const unsigned char* policy_bytes,
  const unsigned char* name_bytes,
  size_t               name_size,
  int64_t              left_coin,
  int64_t              left_amount,
  int64_t              right_coin,
  int64_t              right_amount,
  int64_t              sum_coin,
  int64_t              sum_amount,
  int64_t              delta_coin,
  int64_t              delta_amount)
{
  cardano_blake2b_hash_t* policy = NULL;
  cardano_asset_name_t*   name   = NULL;
  cardano_asset_id_t*     asset  = NULL;
  cardano_asset_id_t*     ada    = NULL;
  cardano_value_t*        left   = NULL;
  cardano_value_t*        right  = NULL;
  cardano_value_t*        sum    = NULL;
  cardano_value_t*        delta  = NULL;
  cardano_error_t         result = cardano_blake2b_hash_from_bytes(policy_bytes, 28, &policy);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_asset_name_from_bytes(name_bytes, name_size, &name);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_asset_id_new(policy, name, &asset);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_asset_id_new_lovelace(&ada);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_new(left_coin, NULL, &left);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_new(right_coin, NULL, &right);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_add_asset(left, policy, name, left_amount);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_add_asset(right, policy, name, right_amount);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_add(left, right, &sum);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_subtract(left, right, &delta);
  }

  int agrees = 0;

  if (result == CARDANO_SUCCESS)
  {
    const unsigned char* asset_bytes = cardano_asset_id_get_bytes(asset);
    agrees                           = (cardano_asset_name_get_bytes_size(name) == name_size) &&
      (memcmp(cardano_asset_name_get_bytes(name), name_bytes, name_size) == 0) &&
      (cardano_asset_id_get_bytes_size(asset) == 28U + name_size) &&
      (memcmp(asset_bytes, policy_bytes, 28) == 0) &&
      (memcmp(asset_bytes + 28, name_bytes, name_size) == 0) &&
      cardano_asset_id_is_lovelace(ada) && !cardano_asset_id_is_lovelace(asset) &&
      (cardano_asset_id_get_bytes_size(ada) == 0) &&
      matches(left, policy, name, left_coin, left_amount) &&
      matches(right, policy, name, right_coin, right_amount) &&
      matches(sum, policy, name, sum_coin, sum_amount) &&
      matches(delta, policy, name, delta_coin, delta_amount);
  }

  cardano_value_unref(&delta);
  cardano_value_unref(&sum);
  cardano_value_unref(&right);
  cardano_value_unref(&left);
  cardano_asset_id_unref(&ada);
  cardano_asset_id_unref(&asset);
  cardano_asset_name_unref(&name);
  cardano_blake2b_hash_unref(&policy);

  return agrees;
}

/**
 * \brief Rebuilds a typed one-asset value and checks CBOR and decoded fields.
 * All input bytes are borrowed through return; each native owner is released
 * on both failure and success. No output buffer escapes this operation.
 */
int
cometa_test_value_cbor(
  const unsigned char* policy_bytes,
  const unsigned char* name_bytes,
  size_t               name_size,
  int64_t              coin,
  int64_t              amount,
  const unsigned char* expected,
  size_t               expected_size)
{
  cardano_blake2b_hash_t* policy  = NULL;
  cardano_asset_name_t*   name    = NULL;
  cardano_value_t*        value   = NULL;
  cardano_value_t*        decoded = NULL;
  cardano_cbor_writer_t*  writer  = cardano_cbor_writer_new();
  cardano_cbor_reader_t*  reader  = cardano_cbor_reader_new(expected, expected_size);
  cardano_buffer_t*       encoded = NULL;
  cardano_error_t         result  = cardano_blake2b_hash_from_bytes(policy_bytes, 28, &policy);
  if ((writer == NULL) || (reader == NULL))
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (result == CARDANO_SUCCESS)
    result = cardano_asset_name_from_bytes(name_bytes, name_size, &name);
  if (result == CARDANO_SUCCESS)
    result = cardano_value_new(coin, NULL, &value);
  if ((result == CARDANO_SUCCESS) && (amount != 0))
    result = cardano_value_add_asset(value, policy, name, amount);
  if (result == CARDANO_SUCCESS)
    result = cardano_value_to_cbor(value, writer);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  if (result == CARDANO_SUCCESS)
    result = cardano_value_from_cbor(reader, &decoded);
  int agrees = 0;
  if (result == CARDANO_SUCCESS)
  {
    agrees = (cardano_buffer_get_size(encoded) == expected_size) &&
      (memcmp(cardano_buffer_get_data(encoded), expected, expected_size) == 0) &&
      matches(decoded, policy, name, coin, amount);
  }
  cardano_buffer_unref(&encoded);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_value_unref(&decoded);
  cardano_value_unref(&value);
  cardano_asset_name_unref(&name);
  cardano_blake2b_hash_unref(&policy);
  return agrees;
}

/** \brief Tests typed mint map encoding and decoding; all owners are scoped. */
int
cometa_test_mint_cbor(const unsigned char* policy_bytes, const unsigned char* name_bytes, size_t name_size, int64_t amount, const unsigned char* expected, size_t size)
{
  cardano_blake2b_hash_t* policy  = NULL;
  cardano_asset_name_t*   name    = NULL;
  cardano_multi_asset_t*  assets  = NULL;
  cardano_multi_asset_t*  decoded = NULL;
  cardano_cbor_writer_t*  writer  = cardano_cbor_writer_new();
  cardano_cbor_reader_t*  reader  = cardano_cbor_reader_new(expected, size);
  cardano_buffer_t*       encoded = NULL;
  cardano_error_t         result  = cardano_blake2b_hash_from_bytes(policy_bytes, 28, &policy);
  if ((writer == NULL) || (reader == NULL))
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (result == CARDANO_SUCCESS)
    result = cardano_asset_name_from_bytes(name_bytes, name_size, &name);
  if (result == CARDANO_SUCCESS)
    result = cardano_multi_asset_new(&assets);
  if (result == CARDANO_SUCCESS)
    result = cardano_multi_asset_set(assets, policy, name, amount);
  if (result == CARDANO_SUCCESS)
    result = cardano_multi_asset_to_cbor(assets, writer);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  if (result == CARDANO_SUCCESS)
    result = cardano_multi_asset_from_cbor(reader, &decoded);
  int64_t actual = 0;
  if (result == CARDANO_SUCCESS)
    result = cardano_multi_asset_get(decoded, policy, name, &actual);
  int agrees = 0;
  if (result == CARDANO_SUCCESS)
    agrees = (actual == amount) && (cardano_buffer_get_size(encoded) == size) && (memcmp(cardano_buffer_get_data(encoded), expected, size) == 0);
  cardano_buffer_unref(&encoded);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_multi_asset_unref(&decoded);
  cardano_multi_asset_unref(&assets);
  cardano_asset_name_unref(&name);
  cardano_blake2b_hash_unref(&policy);
  return agrees;
}

/** \brief Checks an asset name CBOR from exact bytes, with scoped native owners. */
int
cometa_test_name_cbor(const unsigned char* name_bytes, size_t name_size, const unsigned char* expected, size_t size)
{
  cardano_asset_name_t*  name    = NULL;
  cardano_asset_name_t*  decoded = NULL;
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader  = cardano_cbor_reader_new(expected, size);
  cardano_buffer_t*      encoded = NULL;
  cardano_error_t        result  = cardano_asset_name_from_bytes(name_bytes, name_size, &name);
  if ((writer == NULL) || (reader == NULL))
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (result == CARDANO_SUCCESS)
    result = cardano_asset_name_to_cbor(name, writer);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  if (result == CARDANO_SUCCESS)
    result = cardano_asset_name_from_cbor(reader, &decoded);
  int agrees = 0;
  if (result == CARDANO_SUCCESS)
    agrees = (cardano_asset_name_get_bytes_size(decoded) == name_size) &&
      (memcmp(cardano_asset_name_get_bytes(decoded), name_bytes, name_size) == 0) &&
      (cardano_buffer_get_size(encoded) == size) && (memcmp(cardano_buffer_get_data(encoded), expected, size) == 0);
  cardano_buffer_unref(&encoded);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_asset_name_unref(&decoded);
  cardano_asset_name_unref(&name);
  return agrees;
}
