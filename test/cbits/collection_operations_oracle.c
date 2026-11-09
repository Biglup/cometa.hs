/**
 * \file collection_operations_oracle.c
 *
 * \author angel.castillo
 * \date   Nov 09, 2026
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

#include <cardano/cardano.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/* Every reader/writer, map, key list and getter reference is operation-owned.
 * Snapshots use getters instead of multi_asset_to_cbor: that encoder omits empty
 * policies, while these tests must observe their stored state. */
#define TRY(expression)            \
  do                               \
  {                                \
    result = (expression);         \
    if (result != CARDANO_SUCCESS) \
      goto cleanup;                \
  }                                \
  while (0)

static bool
same_bytes(const byte_t* left, size_t left_size, const byte_t* right, size_t right_size)
{
  return left_size == right_size && (left_size == 0U || memcmp(left, right, left_size) == 0);
}

static cardano_error_t
read_ids(cardano_cbor_reader_t* reader, cardano_asset_id_map_t** output)
{
  cardano_asset_id_map_t* map    = NULL;
  cardano_asset_id_t*     key    = NULL;
  cardano_buffer_t*       bytes  = NULL;
  int64_t                 count  = 0;
  int64_t                 amount = 0;
  cardano_error_t         result = cardano_asset_id_map_new(&map);
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  TRY(cardano_cbor_reader_read_start_map(reader, &count));
  if (count < 0)
  {
    result = CARDANO_ERROR_DECODING;
    goto cleanup;
  }
  for (int64_t i = 0; i < count; ++i)
  {
    TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
    if (cardano_buffer_get_size(bytes) == 0U)
      result = cardano_asset_id_new_lovelace(&key);
    else
      result = cardano_asset_id_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &key);
    if (result != CARDANO_SUCCESS)
      goto cleanup;
    TRY(cardano_cbor_reader_read_int(reader, &amount));
    TRY(cardano_asset_id_map_insert(map, key, amount));
    cardano_asset_id_unref(&key);
    key = NULL;
    cardano_buffer_unref(&bytes);
    bytes = NULL;
  }
  TRY(cardano_cbor_reader_read_end_map(reader));
  *output = map;
  map     = NULL;
cleanup:
  cardano_asset_id_unref(&key);
  cardano_buffer_unref(&bytes);
  cardano_asset_id_map_unref(&map);
  return result;
}

/* Snapshot raw entries, first-match lookup values and all index/key-list paths. */
static cardano_error_t
snapshot_ids(cardano_asset_id_map_t* map, cardano_cbor_writer_t* writer)
{
  cardano_asset_id_list_t* keys         = NULL;
  cardano_asset_id_t*      pair_key     = NULL;
  cardano_asset_id_t*      index_key    = NULL;
  cardano_asset_id_t*      listed_key   = NULL;
  int64_t                  amount       = 0;
  int64_t                  index_amount = 0;
  const size_t             count        = cardano_asset_id_map_get_length(map);
  cardano_error_t          result       = cardano_asset_id_map_get_keys(map, &keys);
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  if (cardano_asset_id_list_get_length(keys) != count)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, 2));
  TRY(cardano_cbor_writer_write_start_map(writer, (int64_t)count));
  for (size_t i = 0; i < count; ++i)
  {
    TRY(cardano_asset_id_map_get_key_value_at(map, i, &pair_key, &amount));
    TRY(cardano_asset_id_map_get_key_at(map, i, &index_key));
    TRY(cardano_asset_id_map_get_value_at(map, i, &index_amount));
    TRY(cardano_asset_id_list_get(keys, i, &listed_key));
    const bool same_index  = same_bytes(cardano_asset_id_get_bytes(pair_key), cardano_asset_id_get_bytes_size(pair_key), cardano_asset_id_get_bytes(index_key), cardano_asset_id_get_bytes_size(index_key));
    const bool same_listed = same_bytes(cardano_asset_id_get_bytes(pair_key), cardano_asset_id_get_bytes_size(pair_key), cardano_asset_id_get_bytes(listed_key), cardano_asset_id_get_bytes_size(listed_key));
    if (amount != index_amount || !same_index || !same_listed)
    {
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      goto cleanup;
    }
    TRY(cardano_cbor_writer_write_bytestring(writer, cardano_asset_id_get_bytes(pair_key), cardano_asset_id_get_bytes_size(pair_key)));
    TRY(cardano_cbor_writer_write_signed_int(writer, amount));
    cardano_asset_id_unref(&pair_key);
    pair_key = NULL;
    cardano_asset_id_unref(&index_key);
    index_key = NULL;
    cardano_asset_id_unref(&listed_key);
    listed_key = NULL;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, (int64_t)count));
  for (size_t i = 0; i < count; ++i)
  {
    TRY(cardano_asset_id_map_get_key_at(map, i, &pair_key));
    TRY(cardano_asset_id_map_get(map, pair_key, &amount));
    TRY(cardano_cbor_writer_write_signed_int(writer, amount));
    cardano_asset_id_unref(&pair_key);
    pair_key = NULL;
  }
  if (cardano_asset_id_map_get_key_at(map, count, &pair_key) != CARDANO_ERROR_INDEX_OUT_OF_BOUNDS)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  /* A valid key outside the generated fixture universe must report absence. */
  const byte_t missing[28] = { 250U };
  TRY(cardano_asset_id_from_bytes(missing, sizeof(missing), &pair_key));
  if (cardano_asset_id_map_get(map, pair_key, &amount) != CARDANO_ERROR_ELEMENT_NOT_FOUND)
    result = CARDANO_ERROR_INVALID_ARGUMENT;
cleanup:
  cardano_asset_id_unref(&pair_key);
  cardano_asset_id_unref(&index_key);
  cardano_asset_id_unref(&listed_key);
  cardano_asset_id_list_unref(&keys);
  return result;
}

/* Insert/appending semantics are exercised on real decoded entries, including
 * zero and repeated keys; the original clone must retain its separate state. */
static cardano_error_t
update_ids(cardano_asset_id_map_t* left, cardano_asset_id_map_t* right)
{
  cardano_asset_id_t* key    = NULL;
  int64_t             amount = 0;
  cardano_error_t     result = CARDANO_SUCCESS;
  for (size_t i = 0; i < cardano_asset_id_map_get_length(right); ++i)
  {
    TRY(cardano_asset_id_map_get_key_value_at(right, i, &key, &amount));
    TRY(cardano_asset_id_map_insert(left, key, amount));
    cardano_asset_id_unref(&key);
    key = NULL;
  }
cleanup:
  cardano_asset_id_unref(&key);
  return result;
}

/* Snapshot raw entries, first-match lookup values and all index/key-list paths. */
static cardano_error_t
snapshot_names(cardano_asset_name_map_t* map, cardano_cbor_writer_t* writer)
{
  cardano_asset_name_list_t* keys         = NULL;
  cardano_asset_name_t*      pair_key     = NULL;
  cardano_asset_name_t*      index_key    = NULL;
  cardano_asset_name_t*      listed_key   = NULL;
  int64_t                    amount       = 0;
  int64_t                    index_amount = 0;
  const size_t               count        = cardano_asset_name_map_get_length(map);
  cardano_error_t            result       = cardano_asset_name_map_get_keys(map, &keys);
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  if (cardano_asset_name_list_get_length(keys) != count)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, 2));
  TRY(cardano_cbor_writer_write_start_map(writer, (int64_t)count));
  for (size_t i = 0; i < count; ++i)
  {
    TRY(cardano_asset_name_map_get_key_value_at(map, i, &pair_key, &amount));
    TRY(cardano_asset_name_map_get_key_at(map, i, &index_key));
    TRY(cardano_asset_name_map_get_value_at(map, i, &index_amount));
    TRY(cardano_asset_name_list_get(keys, i, &listed_key));
    const bool same_index  = same_bytes(cardano_asset_name_get_bytes(pair_key), cardano_asset_name_get_bytes_size(pair_key), cardano_asset_name_get_bytes(index_key), cardano_asset_name_get_bytes_size(index_key));
    const bool same_listed = same_bytes(cardano_asset_name_get_bytes(pair_key), cardano_asset_name_get_bytes_size(pair_key), cardano_asset_name_get_bytes(listed_key), cardano_asset_name_get_bytes_size(listed_key));
    if (amount != index_amount || !same_index || !same_listed)
    {
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      goto cleanup;
    }
    TRY(cardano_cbor_writer_write_bytestring(writer, cardano_asset_name_get_bytes(pair_key), cardano_asset_name_get_bytes_size(pair_key)));
    TRY(cardano_cbor_writer_write_signed_int(writer, amount));
    cardano_asset_name_unref(&pair_key);
    pair_key = NULL;
    cardano_asset_name_unref(&index_key);
    index_key = NULL;
    cardano_asset_name_unref(&listed_key);
    listed_key = NULL;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, (int64_t)count));
  for (size_t i = 0; i < count; ++i)
  {
    TRY(cardano_asset_name_map_get_key_at(map, i, &pair_key));
    TRY(cardano_asset_name_map_get(map, pair_key, &amount));
    TRY(cardano_cbor_writer_write_signed_int(writer, amount));
    cardano_asset_name_unref(&pair_key);
    pair_key = NULL;
  }
  if (cardano_asset_name_map_get_key_at(map, count, &pair_key) != CARDANO_ERROR_INDEX_OUT_OF_BOUNDS)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  /* A valid key outside the generated fixture universe must report absence. */
  const byte_t missing[32] = { 250U };
  TRY(cardano_asset_name_from_bytes(missing, sizeof(missing), &pair_key));
  if (cardano_asset_name_map_get(map, pair_key, &amount) != CARDANO_ERROR_ELEMENT_NOT_FOUND)
    result = CARDANO_ERROR_INVALID_ARGUMENT;
cleanup:
  cardano_asset_name_unref(&pair_key);
  cardano_asset_name_unref(&index_key);
  cardano_asset_name_unref(&listed_key);
  cardano_asset_name_list_unref(&keys);
  return result;
}

/* Insert/appending semantics are exercised on real decoded entries, including
 * zero and repeated keys; the original clone must retain its separate state. */
static cardano_error_t
update_names(cardano_asset_name_map_t* left, cardano_asset_name_map_t* right)
{
  cardano_asset_name_t* key    = NULL;
  int64_t               amount = 0;
  cardano_error_t       result = CARDANO_SUCCESS;
  for (size_t i = 0; i < cardano_asset_name_map_get_length(right); ++i)
  {
    TRY(cardano_asset_name_map_get_key_value_at(right, i, &key, &amount));
    TRY(cardano_asset_name_map_insert(left, key, amount));
    cardano_asset_name_unref(&key);
    key = NULL;
  }
cleanup:
  cardano_asset_name_unref(&key);
  return result;
}

/* Snapshot raw entries, first-match lookup values and all index/key-list paths. */
static cardano_error_t
snapshot_withdrawals(cardano_withdrawal_map_t* map, cardano_cbor_writer_t* writer)
{
  cardano_reward_address_list_t* keys         = NULL;
  cardano_reward_address_t*      pair_key     = NULL;
  cardano_reward_address_t*      index_key    = NULL;
  cardano_reward_address_t*      listed_key   = NULL;
  uint64_t                       amount       = 0;
  uint64_t                       index_amount = 0;
  const size_t                   count        = cardano_withdrawal_map_get_length(map);
  cardano_error_t                result       = cardano_withdrawal_map_get_keys(map, &keys);
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  if (cardano_reward_address_list_get_length(keys) != count)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, 2));
  TRY(cardano_cbor_writer_write_start_map(writer, (int64_t)count));
  for (size_t i = 0; i < count; ++i)
  {
    TRY(cardano_withdrawal_map_get_key_value_at(map, i, &pair_key, &amount));
    TRY(cardano_withdrawal_map_get_key_at(map, i, &index_key));
    TRY(cardano_withdrawal_map_get_value_at(map, i, &index_amount));
    TRY(cardano_reward_address_list_get(keys, i, &listed_key));
    const bool same_index  = same_bytes(cardano_reward_address_get_bytes(pair_key), cardano_reward_address_get_bytes_size(pair_key), cardano_reward_address_get_bytes(index_key), cardano_reward_address_get_bytes_size(index_key));
    const bool same_listed = same_bytes(cardano_reward_address_get_bytes(pair_key), cardano_reward_address_get_bytes_size(pair_key), cardano_reward_address_get_bytes(listed_key), cardano_reward_address_get_bytes_size(listed_key));
    if (amount != index_amount || !same_index || !same_listed)
    {
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      goto cleanup;
    }
    TRY(cardano_cbor_writer_write_bytestring(writer, cardano_reward_address_get_bytes(pair_key), cardano_reward_address_get_bytes_size(pair_key)));
    TRY(cardano_cbor_writer_write_uint(writer, amount));
    cardano_reward_address_unref(&pair_key);
    pair_key = NULL;
    cardano_reward_address_unref(&index_key);
    index_key = NULL;
    cardano_reward_address_unref(&listed_key);
    listed_key = NULL;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, (int64_t)count));
  for (size_t i = 0; i < count; ++i)
  {
    TRY(cardano_withdrawal_map_get_key_at(map, i, &pair_key));
    TRY(cardano_withdrawal_map_get(map, pair_key, &amount));
    TRY(cardano_cbor_writer_write_uint(writer, amount));
    cardano_reward_address_unref(&pair_key);
    pair_key = NULL;
  }
  if (cardano_withdrawal_map_get_key_at(map, count, &pair_key) != CARDANO_ERROR_INDEX_OUT_OF_BOUNDS)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  /* A valid key outside the generated fixture universe must report absence. */
  const byte_t missing[29] = { 224U, 250U };
  TRY(cardano_reward_address_from_bytes(missing, sizeof(missing), &pair_key));
  if (cardano_withdrawal_map_get(map, pair_key, &amount) != CARDANO_ERROR_ELEMENT_NOT_FOUND)
    result = CARDANO_ERROR_INVALID_ARGUMENT;
cleanup:
  cardano_reward_address_unref(&pair_key);
  cardano_reward_address_unref(&index_key);
  cardano_reward_address_unref(&listed_key);
  cardano_reward_address_list_unref(&keys);
  return result;
}

/* Insert/appending semantics are exercised on real decoded entries, including
 * zero and repeated keys; the original clone must retain its separate state. */
static cardano_error_t
update_withdrawals(cardano_withdrawal_map_t* left, cardano_withdrawal_map_t* right)
{
  cardano_reward_address_t* key    = NULL;
  uint64_t                  amount = 0;
  cardano_error_t           result = CARDANO_SUCCESS;
  for (size_t i = 0; i < cardano_withdrawal_map_get_length(right); ++i)
  {
    TRY(cardano_withdrawal_map_get_key_value_at(right, i, &key, &amount));
    TRY(cardano_withdrawal_map_insert(left, key, amount));
    cardano_reward_address_unref(&key);
    key = NULL;
  }
cleanup:
  cardano_reward_address_unref(&key);
  return result;
}

static cardano_error_t
snapshot_multi(cardano_multi_asset_t* map, cardano_cbor_writer_t* writer)
{
  cardano_policy_id_list_t* keys       = NULL;
  cardano_blake2b_hash_t*   policy     = NULL;
  cardano_asset_name_map_t* names      = NULL;
  cardano_asset_name_t*     name       = NULL;
  cardano_asset_id_t*       identifier = NULL;
  int64_t                   amount     = 0;
  int64_t                   by_id      = 0;
  const size_t              count      = cardano_multi_asset_get_policy_count(map);
  cardano_error_t           result     = cardano_multi_asset_get_keys(map, &keys);
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  if (cardano_policy_id_list_get_length(keys) != count)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  TRY(cardano_cbor_writer_write_start_map(writer, (int64_t)count));
  for (size_t i = 0; i < count; ++i)
  {
    TRY(cardano_policy_id_list_get(keys, i, &policy));
    TRY(cardano_multi_asset_get_assets(map, policy, &names));
    TRY(cardano_cbor_writer_write_bytestring(writer, cardano_blake2b_hash_get_data(policy), cardano_blake2b_hash_get_bytes_size(policy)));
    TRY(snapshot_names(names, writer));
    for (size_t j = 0; j < cardano_asset_name_map_get_length(names); ++j)
    {
      TRY(cardano_asset_name_map_get_key_at(names, j, &name));
      TRY(cardano_multi_asset_get(map, policy, name, &amount));
      TRY(cardano_asset_id_new(policy, name, &identifier));
      TRY(cardano_multi_asset_get_with_id(map, identifier, &by_id));
      if (amount != by_id)
      {
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        goto cleanup;
      }
      cardano_asset_id_unref(&identifier);
      identifier = NULL;
      cardano_asset_name_unref(&name);
      name = NULL;
    }
    cardano_asset_name_map_unref(&names);
    names = NULL;
    cardano_blake2b_hash_unref(&policy);
    policy = NULL;
  }
  const byte_t missing[28] = { 250U };
  TRY(cardano_blake2b_hash_from_bytes(missing, sizeof(missing), &policy));
  if (cardano_multi_asset_get_assets(map, policy, &names) != CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  TRY(cardano_asset_name_from_bytes(missing, 0, &name));
  TRY(cardano_asset_id_new(policy, name, &identifier));
  if (cardano_multi_asset_get_with_id(map, identifier, &by_id) != CARDANO_ERROR_ELEMENT_NOT_FOUND)
    result = CARDANO_ERROR_INVALID_ARGUMENT;
cleanup:
  cardano_asset_id_unref(&identifier);
  cardano_asset_name_unref(&name);
  cardano_asset_name_map_unref(&names);
  cardano_blake2b_hash_unref(&policy);
  cardano_policy_id_list_unref(&keys);
  return result;
}

static cardano_error_t
update_multi(cardano_multi_asset_t* left, cardano_multi_asset_t* right, bool individual)
{
  cardano_policy_id_list_t* keys   = NULL;
  cardano_blake2b_hash_t*   policy = NULL;
  cardano_asset_name_map_t* names  = NULL;
  cardano_asset_name_t*     name   = NULL;
  int64_t                   amount = 0;
  cardano_error_t           result = cardano_multi_asset_get_keys(right, &keys);
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  for (size_t i = 0; i < cardano_policy_id_list_get_length(keys); ++i)
  {
    TRY(cardano_policy_id_list_get(keys, i, &policy));
    TRY(cardano_multi_asset_get_assets(right, policy, &names));
    if (!individual)
      TRY(cardano_multi_asset_insert_assets(left, policy, names));
    else
    {
      for (size_t j = 0; j < cardano_asset_name_map_get_length(names); ++j)
      {
        TRY(cardano_asset_name_map_get_key_value_at(names, j, &name, &amount));
        TRY(cardano_multi_asset_set(left, policy, name, amount));
        cardano_asset_name_unref(&name);
        name = NULL;
      }
    }
    cardano_asset_name_map_unref(&names);
    names = NULL;
    cardano_blake2b_hash_unref(&policy);
    policy = NULL;
  }
cleanup:
  cardano_asset_name_unref(&name);
  cardano_asset_name_map_unref(&names);
  cardano_blake2b_hash_unref(&policy);
  cardano_policy_id_list_unref(&keys);
  return result;
}

/* DEFINITIONS ***************************************************************/

/* Kinds: 0 asset-id maps, 1 asset-name maps, 2 withdrawals, 3 multiasset.
 * Operations: 0 snapshot, 1 update, 2 add, 3 subtract, 4 individual multiasset
 * set. Reply: [result snapshot, independent original clone, untouched right,
 * structural equality of result/right (null when no native equals exists)].
 * Input/output spans are borrowed through return; no native owner escapes. */
int
cometa_test_collection_operation(unsigned int kind, unsigned int operation, const unsigned char* left_bytes, size_t left_size, const unsigned char* right_bytes, size_t right_size, unsigned char* output, size_t capacity, size_t* output_size)
{
  cardano_cbor_reader_t*    left_reader            = cardano_cbor_reader_new(left_bytes, left_size);
  cardano_cbor_reader_t*    right_reader           = cardano_cbor_reader_new(right_bytes, right_size);
  cardano_cbor_writer_t*    writer                 = cardano_cbor_writer_new();
  cardano_error_t           result                 = CARDANO_ERROR_INVALID_ARGUMENT;
  size_t                    remaining              = 0;
  cardano_asset_id_map_t*   ids_left               = NULL;
  cardano_asset_id_map_t*   ids_right              = NULL;
  cardano_asset_id_map_t*   ids_clone              = NULL;
  cardano_asset_id_map_t*   ids_arithmetic         = NULL;
  cardano_asset_name_map_t* names_left             = NULL;
  cardano_asset_name_map_t* names_right            = NULL;
  cardano_asset_name_map_t* names_clone            = NULL;
  cardano_asset_name_map_t* names_arithmetic       = NULL;
  cardano_withdrawal_map_t* withdrawals_left       = NULL;
  cardano_withdrawal_map_t* withdrawals_right      = NULL;
  cardano_withdrawal_map_t* withdrawals_clone      = NULL;
  cardano_withdrawal_map_t* withdrawals_arithmetic = NULL;
  cardano_multi_asset_t*    multi_left             = NULL;
  cardano_multi_asset_t*    multi_right            = NULL;
  cardano_multi_asset_t*    multi_clone            = NULL;
  cardano_multi_asset_t*    multi_arithmetic       = NULL;
  if (output_size == NULL)
    goto cleanup;
  *output_size = 0;
  if (left_reader == NULL || right_reader == NULL || writer == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  if (operation > 4U || kind > 3U || (kind == 2U && operation > 1U) || (operation == 4U && kind != 3U))
    goto cleanup;
  TRY(cardano_cbor_writer_write_start_array(writer, 4));
  switch (kind)
  {
    case 0U:
      TRY(read_ids(left_reader, &ids_left));
      TRY(read_ids(right_reader, &ids_right));
      TRY(cardano_asset_id_map_deep_clone(ids_left, &ids_clone));
      if (operation == 1U)
        TRY(update_ids(ids_left, ids_right));
      if (operation == 2U)
        TRY(cardano_asset_id_map_add(ids_left, ids_right, &ids_arithmetic));
      if (operation == 3U)
        TRY(cardano_asset_id_map_subtract(ids_left, ids_right, &ids_arithmetic));
      TRY(snapshot_ids(ids_arithmetic == NULL ? ids_left : ids_arithmetic, writer));
      TRY(snapshot_ids(ids_clone, writer));
      TRY(snapshot_ids(ids_right, writer));
      TRY(cardano_cbor_writer_write_bool(writer, cardano_asset_id_map_equals(ids_arithmetic == NULL ? ids_left : ids_arithmetic, ids_right)));
      break;
    case 1U:
      TRY(cardano_asset_name_map_from_cbor(left_reader, &names_left));
      TRY(cardano_asset_name_map_from_cbor(right_reader, &names_right));
      TRY(cardano_asset_name_map_deep_clone(names_left, &names_clone));
      if (operation == 1U)
        TRY(update_names(names_left, names_right));
      if (operation == 2U)
        TRY(cardano_asset_name_map_add(names_left, names_right, &names_arithmetic));
      if (operation == 3U)
        TRY(cardano_asset_name_map_subtract(names_left, names_right, &names_arithmetic));
      TRY(snapshot_names(names_arithmetic == NULL ? names_left : names_arithmetic, writer));
      TRY(snapshot_names(names_clone, writer));
      TRY(snapshot_names(names_right, writer));
      TRY(cardano_cbor_writer_write_bool(writer, cardano_asset_name_map_equals(names_arithmetic == NULL ? names_left : names_arithmetic, names_right)));
      break;
    case 2U:
      TRY(cardano_withdrawal_map_from_cbor(left_reader, &withdrawals_left));
      TRY(cardano_withdrawal_map_from_cbor(right_reader, &withdrawals_right));
      TRY(cardano_withdrawal_map_deep_clone(withdrawals_left, &withdrawals_clone));
      if (operation == 1U)
        TRY(update_withdrawals(withdrawals_left, withdrawals_right));
      TRY(snapshot_withdrawals(withdrawals_arithmetic == NULL ? withdrawals_left : withdrawals_arithmetic, writer));
      TRY(snapshot_withdrawals(withdrawals_clone, writer));
      TRY(snapshot_withdrawals(withdrawals_right, writer));
      TRY(cardano_cbor_writer_write_null(writer));
      break;
    case 3U:
      TRY(cardano_multi_asset_from_cbor(left_reader, &multi_left));
      TRY(cardano_multi_asset_from_cbor(right_reader, &multi_right));
      TRY(cardano_multi_asset_deep_clone(multi_left, &multi_clone));
      if (operation == 1U || operation == 4U)
        TRY(update_multi(multi_left, multi_right, operation == 4U));
      if (operation == 2U)
        TRY(cardano_multi_asset_add(multi_left, multi_right, &multi_arithmetic));
      if (operation == 3U)
        TRY(cardano_multi_asset_subtract(multi_left, multi_right, &multi_arithmetic));
      TRY(snapshot_multi(multi_arithmetic == NULL ? multi_left : multi_arithmetic, writer));
      TRY(snapshot_multi(multi_clone, writer));
      TRY(snapshot_multi(multi_right, writer));
      TRY(cardano_cbor_writer_write_bool(writer, cardano_multi_asset_equals(multi_arithmetic == NULL ? multi_left : multi_arithmetic, multi_right)));
      break;
  }
  TRY(cardano_cbor_reader_get_bytes_remaining(left_reader, &remaining));
  if (remaining != 0U)
  {
    result = CARDANO_ERROR_DECODING;
    goto cleanup;
  }
  TRY(cardano_cbor_reader_get_bytes_remaining(right_reader, &remaining));
  if (remaining != 0U)
  {
    result = CARDANO_ERROR_DECODING;
    goto cleanup;
  }
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_asset_id_map_unref(&ids_left);
  ids_left = NULL;
  cardano_asset_id_map_unref(&ids_right);
  ids_right = NULL;
  cardano_asset_id_map_unref(&ids_clone);
  ids_clone = NULL;
  cardano_asset_id_map_unref(&ids_arithmetic);
  ids_arithmetic = NULL;
  cardano_asset_name_map_unref(&names_left);
  names_left = NULL;
  cardano_asset_name_map_unref(&names_right);
  names_right = NULL;
  cardano_asset_name_map_unref(&names_clone);
  names_clone = NULL;
  cardano_asset_name_map_unref(&names_arithmetic);
  names_arithmetic = NULL;
  cardano_withdrawal_map_unref(&withdrawals_left);
  withdrawals_left = NULL;
  cardano_withdrawal_map_unref(&withdrawals_right);
  withdrawals_right = NULL;
  cardano_withdrawal_map_unref(&withdrawals_clone);
  withdrawals_clone = NULL;
  cardano_withdrawal_map_unref(&withdrawals_arithmetic);
  withdrawals_arithmetic = NULL;
  cardano_multi_asset_unref(&multi_left);
  multi_left = NULL;
  cardano_multi_asset_unref(&multi_right);
  multi_right = NULL;
  cardano_multi_asset_unref(&multi_clone);
  multi_clone = NULL;
  cardano_multi_asset_unref(&multi_arithmetic);
  multi_arithmetic = NULL;
  cardano_cbor_reader_unref(&left_reader);
  left_reader = NULL;
  cardano_cbor_reader_unref(&right_reader);
  right_reader = NULL;
  cardano_cbor_writer_unref(&writer);
  writer = NULL;
  return (int)result;
}

#undef TRY
