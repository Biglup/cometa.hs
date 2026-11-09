/**
 * \file transaction_map_operations_oracle.c
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

#define TRY(expression)            \
  do                               \
  {                                \
    result = (expression);         \
    if (result != CARDANO_SUCCESS) \
      goto cleanup;                \
  }                                \
  while (0)

static cardano_error_t
write_bytes(cardano_cbor_writer_t* child, cardano_cbor_writer_t* writer)
{
  cardano_buffer_t* bytes  = NULL;
  cardano_error_t   result = cardano_cbor_writer_encode_in_buffer(child, &bytes);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_write_bytestring(writer, cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes));
  cardano_buffer_unref(&bytes);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_reset(child);
  return result;
}

static cardano_error_t
write_reward(cardano_reward_address_t* key, cardano_cbor_writer_t* writer)
{
  byte_t          bytes[29];
  cardano_error_t result = cardano_reward_address_to_bytes(key, bytes, sizeof(bytes));
  return result == CARDANO_SUCCESS ? cardano_cbor_writer_write_bytestring(writer, bytes, sizeof(bytes)) : result;
}

/* DEFINITIONS ****************************************************************/

int
cometa_test_withdrawal_operations(const byte_t* input, size_t size, const char* text, size_t text_size, uint64_t amount, const byte_t* value_bytes, size_t value_size, size_t index, byte_t* output, size_t capacity, size_t* output_size)
{
  cardano_withdrawal_map_t* map       = NULL;
  cardano_reward_address_t* key       = NULL;
  cardano_reward_address_t* pair_key  = NULL;
  cardano_cbor_reader_t*    reader    = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t*    writer    = cardano_cbor_writer_new();
  cardano_cbor_writer_t*    child     = cardano_cbor_writer_new();
  cardano_error_t           result    = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  cardano_error_t           insertion = CARDANO_SUCCESS;
  if (reader == NULL || writer == NULL || child == NULL)
    goto cleanup;
  CARDANO_UNUSED(value_bytes);
  CARDANO_UNUSED(value_size);
  if (size == 1U && input[0] == 0xa0U)
  {
    TRY(cardano_withdrawal_map_new(&map));
  }
  else
  {
    TRY(cardano_withdrawal_map_from_cbor(reader, &map));
  }
  if (text_size != 0U)
    insertion = cardano_withdrawal_map_insert_ex(map, text, text_size, amount);
  TRY(cardano_cbor_writer_write_start_array(writer, 5));
  TRY(cardano_cbor_writer_write_bool(writer, insertion == CARDANO_SUCCESS));
  CARDANO_UNUSED(index);
  TRY(cardano_cbor_writer_write_null(writer));
  TRY(cardano_cbor_writer_write_null(writer));
  TRY(cardano_cbor_writer_write_uint(writer, cardano_withdrawal_map_get_length(map)));
  TRY(cardano_withdrawal_map_to_cbor(map, child));
  TRY(write_bytes(child, writer));
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_reward_address_unref(&key);
  cardano_reward_address_unref(&pair_key);
  cardano_withdrawal_map_unref(&map);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_writer_unref(&child);
  return (int)result;
}

int
cometa_test_direct_deposit_operations(const byte_t* input, size_t size, const char* text, size_t text_size, uint64_t amount, const byte_t* value_bytes, size_t value_size, size_t index, byte_t* output, size_t capacity, size_t* output_size)
{
  cardano_direct_deposit_map_t* map        = NULL;
  cardano_reward_address_t*     key        = NULL;
  cardano_reward_address_t*     pair_key   = NULL;
  uint64_t                      value      = 0U;
  uint64_t                      pair_value = 0U;
  cardano_cbor_reader_t*        reader     = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t*        writer     = cardano_cbor_writer_new();
  cardano_cbor_writer_t*        child      = cardano_cbor_writer_new();
  cardano_error_t               result     = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  cardano_error_t               insertion  = CARDANO_SUCCESS;
  if (reader == NULL || writer == NULL || child == NULL)
    goto cleanup;
  CARDANO_UNUSED(value_bytes);
  CARDANO_UNUSED(value_size);
  if (size == 1U && input[0] == 0xa0U)
  {
    TRY(cardano_direct_deposit_map_new(&map));
  }
  else
  {
    TRY(cardano_direct_deposit_map_from_cbor(reader, &map));
  }
  if (text_size != 0U)
    insertion = cardano_direct_deposit_map_insert_ex(map, text, text_size, amount);
  TRY(cardano_cbor_writer_write_start_array(writer, 5));
  TRY(cardano_cbor_writer_write_bool(writer, insertion == CARDANO_SUCCESS));
  const cardano_error_t selected     = cardano_direct_deposit_map_get_key_value_at(map, index, &pair_key, &pair_value);
  const cardano_error_t key_result   = cardano_direct_deposit_map_get_key_at(map, index, &key);
  const cardano_error_t value_result = cardano_direct_deposit_map_get_value_at(map, index, &value);
  if (selected != key_result || selected != value_result)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  if (selected != CARDANO_SUCCESS && selected != CARDANO_ERROR_INDEX_OUT_OF_BOUNDS)
  {
    result = selected;
    goto cleanup;
  }
  for (size_t i = 0U; i < 2U; ++i)
  {
    if (selected == CARDANO_SUCCESS)
    {
      TRY(cardano_cbor_writer_write_start_array(writer, 2));
      TRY(write_reward(i == 0U ? key : pair_key, writer));
      TRY(cardano_cbor_writer_write_uint(writer, i == 0U ? value : pair_value));
    }
    else
      TRY(cardano_cbor_writer_write_null(writer));
  }
  TRY(cardano_cbor_writer_write_uint(writer, cardano_direct_deposit_map_get_length(map)));
  TRY(cardano_direct_deposit_map_to_cbor(map, child));
  TRY(write_bytes(child, writer));
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_reward_address_unref(&key);
  cardano_reward_address_unref(&pair_key);
  cardano_direct_deposit_map_unref(&map);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_writer_unref(&child);
  return (int)result;
}

int
cometa_test_account_balance_intervals_operations(const byte_t* input, size_t size, const char* text, size_t text_size, uint64_t amount, const byte_t* value_bytes, size_t value_size, size_t index, byte_t* output, size_t capacity, size_t* output_size)
{
  cardano_account_balance_intervals_map_t* map          = NULL;
  cardano_reward_address_t*                key          = NULL;
  cardano_reward_address_t*                pair_key     = NULL;
  cardano_account_balance_interval_t*      value        = NULL;
  cardano_account_balance_interval_t*      pair_value   = NULL;
  cardano_account_balance_interval_t*      inserted     = NULL;
  cardano_cbor_reader_t*                   value_reader = NULL;
  cardano_cbor_reader_t*                   reader       = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t*                   writer       = cardano_cbor_writer_new();
  cardano_cbor_writer_t*                   child        = cardano_cbor_writer_new();
  cardano_error_t                          result       = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  cardano_error_t                          insertion    = CARDANO_SUCCESS;
  if (reader == NULL || writer == NULL || child == NULL)
    goto cleanup;
  CARDANO_UNUSED(amount);
  if (size == 1U && input[0] == 0xa0U)
  {
    TRY(cardano_account_balance_intervals_map_new(&map));
  }
  else
  {
    TRY(cardano_account_balance_intervals_map_from_cbor(reader, &map));
  }
  if (text_size != 0U)
  {
    value_reader = cardano_cbor_reader_new(value_bytes, value_size);
    if (value_reader == NULL)
      goto cleanup;
    TRY(cardano_account_balance_interval_from_cbor(value_reader, &inserted));
    insertion = cardano_account_balance_intervals_map_insert_ex(map, text, text_size, inserted);
  }
  TRY(cardano_cbor_writer_write_start_array(writer, 5));
  TRY(cardano_cbor_writer_write_bool(writer, insertion == CARDANO_SUCCESS));
  const cardano_error_t selected     = cardano_account_balance_intervals_map_get_key_value_at(map, index, &pair_key, &pair_value);
  const cardano_error_t key_result   = cardano_account_balance_intervals_map_get_key_at(map, index, &key);
  const cardano_error_t value_result = cardano_account_balance_intervals_map_get_value_at(map, index, &value);
  if (selected != key_result || selected != value_result)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  if (selected != CARDANO_SUCCESS && selected != CARDANO_ERROR_INDEX_OUT_OF_BOUNDS)
  {
    result = selected;
    goto cleanup;
  }
  for (size_t i = 0U; i < 2U; ++i)
  {
    if (selected == CARDANO_SUCCESS)
    {
      TRY(cardano_cbor_writer_write_start_array(writer, 2));
      TRY(write_reward(i == 0U ? key : pair_key, writer));
      if ((i == 0U ? value : pair_value) == NULL)
        TRY(cardano_cbor_writer_write_null(writer));
      else
      {
        TRY(cardano_account_balance_interval_to_cbor(i == 0U ? value : pair_value, child));
        TRY(write_bytes(child, writer));
      }
    }
    else
      TRY(cardano_cbor_writer_write_null(writer));
  }
  TRY(cardano_cbor_writer_write_uint(writer, cardano_account_balance_intervals_map_get_length(map)));
  TRY(cardano_account_balance_intervals_map_to_cbor(map, child));
  TRY(write_bytes(child, writer));
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_reward_address_unref(&key);
  cardano_reward_address_unref(&pair_key);
  cardano_account_balance_interval_unref(&value);
  cardano_account_balance_interval_unref(&pair_value);
  cardano_account_balance_interval_unref(&inserted);
  cardano_cbor_reader_unref(&value_reader);
  cardano_account_balance_intervals_map_unref(&map);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_writer_unref(&child);
  return (int)result;
}

int
cometa_test_required_guards_operations(const byte_t* input, size_t size, const char* text, size_t text_size, uint64_t amount, const byte_t* value_bytes, size_t value_size, size_t index, byte_t* output, size_t capacity, size_t* output_size)
{
  cardano_required_guards_map_t* map        = NULL;
  cardano_credential_t*          key        = NULL;
  cardano_credential_t*          pair_key   = NULL;
  cardano_plutus_data_t*         value      = NULL;
  cardano_plutus_data_t*         pair_value = NULL;
  cardano_cbor_reader_t*         reader     = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t*         writer     = cardano_cbor_writer_new();
  cardano_cbor_writer_t*         child      = cardano_cbor_writer_new();
  cardano_error_t                result     = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  cardano_error_t                insertion  = CARDANO_SUCCESS;
  if (reader == NULL || writer == NULL || child == NULL)
    goto cleanup;
  CARDANO_UNUSED(value_bytes);
  CARDANO_UNUSED(value_size);
  CARDANO_UNUSED(text);
  CARDANO_UNUSED(text_size);
  CARDANO_UNUSED(amount);
  if (size == 1U && input[0] == 0xa0U)
  {
    TRY(cardano_required_guards_map_new(&map));
  }
  else
  {
    TRY(cardano_required_guards_map_from_cbor(reader, &map));
  }
  TRY(cardano_cbor_writer_write_start_array(writer, 5));
  TRY(cardano_cbor_writer_write_bool(writer, insertion == CARDANO_SUCCESS));
  const cardano_error_t selected     = cardano_required_guards_map_get_key_value_at(map, index, &pair_key, &pair_value);
  const cardano_error_t key_result   = cardano_required_guards_map_get_key_at(map, index, &key);
  const cardano_error_t value_result = cardano_required_guards_map_get_value_at(map, index, &value);
  if (selected != key_result || selected != value_result)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  if (selected != CARDANO_SUCCESS && selected != CARDANO_ERROR_INDEX_OUT_OF_BOUNDS)
  {
    result = selected;
    goto cleanup;
  }
  for (size_t i = 0U; i < 2U; ++i)
  {
    if (selected == CARDANO_SUCCESS)
    {
      TRY(cardano_cbor_writer_write_start_array(writer, 2));
      TRY(cardano_credential_to_cbor(i == 0U ? key : pair_key, child));
      TRY(write_bytes(child, writer));
      if ((i == 0U ? value : pair_value) == NULL)
        TRY(cardano_cbor_writer_write_null(writer));
      else
      {
        TRY(cardano_plutus_data_to_cbor(i == 0U ? value : pair_value, child));
        TRY(write_bytes(child, writer));
      }
    }
    else
      TRY(cardano_cbor_writer_write_null(writer));
  }
  TRY(cardano_cbor_writer_write_uint(writer, cardano_required_guards_map_get_length(map)));
  TRY(cardano_required_guards_map_to_cbor(map, child));
  TRY(write_bytes(child, writer));
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_credential_unref(&key);
  cardano_credential_unref(&pair_key);
  cardano_plutus_data_unref(&value);
  cardano_plutus_data_unref(&pair_value);
  cardano_required_guards_map_unref(&map);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_writer_unref(&child);
  return (int)result;
}

/* The input is an ordered array of [input, redeemer] pairs. Insert appends even
 * duplicate inputs. Clone owns independent nested values; mutate the source
 * after cloning, then release it before observing the clone's getters. */
int
cometa_test_input_redeemer_operations(const byte_t* input, size_t size, const byte_t* target, size_t target_size, size_t index, byte_t* output, size_t capacity, size_t* output_size)
{
  cardano_input_to_redeemer_map_t* map           = NULL;
  cardano_input_to_redeemer_map_t* clone         = NULL;
  cardano_transaction_input_t*     key           = NULL;
  cardano_transaction_input_t*     pair_key      = NULL;
  cardano_transaction_input_t*     query         = NULL;
  cardano_redeemer_t*              value         = NULL;
  cardano_redeemer_t*              pair_value    = NULL;
  cardano_redeemer_t*              found         = NULL;
  cardano_cbor_reader_t*           reader        = cardano_cbor_reader_new(input, size);
  cardano_cbor_reader_t*           target_reader = cardano_cbor_reader_new(target, target_size);
  cardano_cbor_writer_t*           writer        = cardano_cbor_writer_new();
  cardano_cbor_writer_t*           child         = cardano_cbor_writer_new();
  cardano_error_t                  result        = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  int64_t                          count         = 0;
  int64_t                          arity         = 0;
  if (reader == NULL || target_reader == NULL || writer == NULL || child == NULL)
    goto cleanup;
  TRY(cardano_input_to_redeemer_map_new(&map));
  TRY(cardano_cbor_reader_read_start_array(reader, &count));
  if (count < 0)
  {
    result = CARDANO_ERROR_DECODING;
    goto cleanup;
  }
  for (int64_t i = 0; i < count; ++i)
  {
    TRY(cardano_cbor_reader_read_start_array(reader, &arity));
    if (arity != 2)
    {
      result = CARDANO_ERROR_DECODING;
      goto cleanup;
    }
    TRY(cardano_transaction_input_from_cbor(reader, &key));
    TRY(cardano_redeemer_from_cbor(reader, &value));
    TRY(cardano_cbor_reader_read_end_array(reader));
    TRY(cardano_input_to_redeemer_map_insert(map, key, value));
    cardano_transaction_input_unref(&key);
    key = NULL;
    cardano_redeemer_unref(&value);
    value = NULL;
  }
  TRY(cardano_cbor_reader_read_end_array(reader));
  TRY(cardano_transaction_input_from_cbor(target_reader, &query));
  TRY(cardano_input_to_redeemer_map_deep_clone(map, &clone));
  if (count > 0)
  {
    TRY(cardano_input_to_redeemer_map_get_key_at(map, 0U, &key));
    TRY(cardano_input_to_redeemer_map_update_redeemer_index(map, key, 999U));
    cardano_transaction_input_unref(&key);
    key = NULL;
  }
  cardano_input_to_redeemer_map_unref(&map);
  map                          = NULL;
  const cardano_error_t lookup = cardano_input_to_redeemer_map_get(clone, query, &found);
  if (lookup != CARDANO_SUCCESS && lookup != CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    result = lookup;
    goto cleanup;
  }
  const cardano_error_t selected     = cardano_input_to_redeemer_map_get_key_value_at(clone, index, &pair_key, &pair_value);
  const cardano_error_t key_result   = cardano_input_to_redeemer_map_get_key_at(clone, index, &key);
  const cardano_error_t value_result = cardano_input_to_redeemer_map_get_value_at(clone, index, &value);
  if (selected != key_result || selected != value_result)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  if (selected != CARDANO_SUCCESS && selected != CARDANO_ERROR_INDEX_OUT_OF_BOUNDS)
  {
    result = selected;
    goto cleanup;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, 4));
  TRY(cardano_cbor_writer_write_uint(writer, cardano_input_to_redeemer_map_get_length(clone)));
  if (found == NULL)
    TRY(cardano_cbor_writer_write_null(writer));
  else
  {
    TRY(cardano_redeemer_to_cbor(found, child));
    TRY(write_bytes(child, writer));
  }
  for (size_t i = 0U; i < 2U; ++i)
  {
    if (selected != CARDANO_SUCCESS)
      TRY(cardano_cbor_writer_write_null(writer));
    else
    {
      TRY(cardano_cbor_writer_write_start_array(writer, 2));
      TRY(cardano_transaction_input_to_cbor(i == 0U ? key : pair_key, child));
      TRY(write_bytes(child, writer));
      TRY(cardano_redeemer_to_cbor(i == 0U ? value : pair_value, child));
      TRY(write_bytes(child, writer));
    }
  }
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_transaction_input_unref(&key);
  cardano_transaction_input_unref(&pair_key);
  cardano_transaction_input_unref(&query);
  cardano_redeemer_unref(&value);
  cardano_redeemer_unref(&pair_value);
  cardano_redeemer_unref(&found);
  cardano_input_to_redeemer_map_unref(&map);
  cardano_input_to_redeemer_map_unref(&clone);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_reader_unref(&target_reader);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_writer_unref(&child);
  return (int)result;
}

int
cometa_test_subtransaction_find(const byte_t* input, size_t size, const byte_t* identifier, size_t identifier_size, byte_t* output, size_t capacity, size_t* output_size)
{
  cardano_sub_transaction_set_t* set    = NULL;
  cardano_sub_transaction_t*     found  = NULL;
  cardano_blake2b_hash_t*        hash   = NULL;
  cardano_cbor_reader_t*         reader = size == 0U ? NULL : cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t*         writer = cardano_cbor_writer_new();
  cardano_error_t                result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if ((size != 0U && reader == NULL) || writer == NULL)
    goto cleanup;
  /* Empty input requests a freshly constructed set, not an empty CBOR
   * import: native import explicitly rejects an empty set array. */
  if (size == 0U)
  {
    TRY(cardano_sub_transaction_set_new(&set));
  }
  else
  {
    TRY(cardano_sub_transaction_set_from_cbor(reader, &set));
  }
  TRY(cardano_blake2b_hash_from_bytes(identifier, identifier_size, &hash));
  result = cardano_sub_transaction_set_find_by_id(set, hash, &found);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    TRY(cardano_cbor_writer_write_null(writer));
  }
  else
  {
    if (result != CARDANO_SUCCESS)
      goto cleanup;
    cardano_sub_transaction_set_unref(&set);
    set = NULL;
    TRY(cardano_sub_transaction_to_cbor(found, writer));
  }
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_sub_transaction_unref(&found);
  cardano_sub_transaction_set_unref(&set);
  cardano_blake2b_hash_unref(&hash);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  return (int)result;
}

#undef TRY
