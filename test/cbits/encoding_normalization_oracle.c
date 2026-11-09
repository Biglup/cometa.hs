/**
 * \file encoding_normalization_oracle.c
 *
 * \author angel.castillo
 * \date Nov 09, 2026
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
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

static bool
equal_buffers(const cardano_buffer_t* first, const cardano_buffer_t* second)
{
  return cardano_buffer_get_size(first) == cardano_buffer_get_size(second) &&
    memcmp(cardano_buffer_get_data(first), cardano_buffer_get_data(second), cardano_buffer_get_size(first)) == 0;
}

/* The oracle clears a deep-cloned owner, never a caller's signed source. The
 * original is serialized before and after to prove descendant caches are not
 * shared across clones. All outputs are owned buffers and every partial native
 * owner is released before return. No callback or mutable owner escapes. */
#define NORMALIZE_CASE(type, prefix)                                         \
  do                                                                         \
  {                                                                          \
    type*                  source        = NULL;                             \
    type*                  copy          = NULL;                             \
    cardano_cbor_writer_t* before_writer = cardano_cbor_writer_new();        \
    cardano_cbor_writer_t* after_writer  = cardano_cbor_writer_new();        \
    cardano_buffer_t*      before        = NULL;                             \
    cardano_buffer_t*      after         = NULL;                             \
    if (before_writer == NULL || after_writer == NULL)                       \
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;                       \
    if (result == CARDANO_SUCCESS)                                           \
      result = prefix##_from_cbor(reader, &source);                          \
    if (result == CARDANO_SUCCESS)                                           \
      result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);  \
    if (result == CARDANO_SUCCESS && remaining != 0U)                        \
      result = CARDANO_ERROR_DECODING;                                       \
    if (result == CARDANO_SUCCESS)                                           \
      result = prefix##_deep_clone(source, &copy);                           \
    if (result == CARDANO_SUCCESS)                                           \
      result = prefix##_to_cbor(source, before_writer);                      \
    if (result == CARDANO_SUCCESS)                                           \
      result = cardano_cbor_writer_encode_in_buffer(before_writer, &before); \
    if (result == CARDANO_SUCCESS)                                           \
    {                                                                        \
      prefix##_clear_cbor_cache(copy);                                       \
      result = prefix##_to_cbor(copy, writer);                               \
    }                                                                        \
    if (result == CARDANO_SUCCESS)                                           \
      result = prefix##_to_cbor(source, after_writer);                       \
    if (result == CARDANO_SUCCESS)                                           \
      result = cardano_cbor_writer_encode_in_buffer(after_writer, &after);   \
    if (result == CARDANO_SUCCESS && !equal_buffers(before, after))          \
      result = CARDANO_ERROR_INVALID_CBOR_VALUE;                             \
    cardano_buffer_unref(&before);                                           \
    cardano_buffer_unref(&after);                                            \
    cardano_cbor_writer_unref(&before_writer);                               \
    cardano_cbor_writer_unref(&after_writer);                                \
    prefix##_unref(&source);                                                 \
    prefix##_unref(&copy);                                                   \
  }                                                                          \
  while (0)

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_test_encoding_normalize(unsigned int kind, const unsigned char* bytes, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
    return CARDANO_ERROR_POINTER_IS_NULL;
  *output                          = NULL;
  cardano_cbor_reader_t* reader    = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_writer_t* writer    = cardano_cbor_writer_new();
  size_t                 remaining = 0U;
  cardano_error_t        result    = reader == NULL || writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;
  if (result == CARDANO_SUCCESS)
  {
    switch (kind)
    {
      case 0U:
        NORMALIZE_CASE(cardano_native_script_t, cardano_native_script);
        break;
      case 1U:
        NORMALIZE_CASE(cardano_native_script_list_t, cardano_native_script_list);
        break;
      case 2U:
        NORMALIZE_CASE(cardano_transaction_t, cardano_transaction);
        break;
      case 3U:
        NORMALIZE_CASE(cardano_sub_transaction_t, cardano_sub_transaction);
        break;
      case 4U:
      {
        cardano_blake2b_hash_t* source = NULL;
        cardano_blake2b_hash_t* copy   = NULL;
        result                         = cardano_blake2b_hash_from_cbor(reader, &source);
        if (result == CARDANO_SUCCESS)
          result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
        if (result == CARDANO_SUCCESS && remaining != 0U)
          result = CARDANO_ERROR_DECODING;
        if (result == CARDANO_SUCCESS)
          result = cardano_blake2b_hash_deep_clone(source, &copy);
        cardano_blake2b_hash_unref(&source);
        if (result == CARDANO_SUCCESS)
          result = cardano_blake2b_hash_to_cbor(copy, writer);
        cardano_blake2b_hash_unref(&copy);
        break;
      }
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  if (result != CARDANO_SUCCESS)
    cardano_buffer_unref(output);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  return (unsigned int)result;
}

#undef NORMALIZE_CASE

/* Serialize stored associations through getters. multi_asset_to_cbor drops
 * empty policy groups, so it cannot prove a raw Value clone contract. */
static cardano_error_t
write_raw_value(cardano_value_t* value, cardano_cbor_writer_t* writer)
{
  cardano_multi_asset_t*    assets   = cardano_value_get_multi_asset(value);
  cardano_policy_id_list_t* policies = NULL;
  cardano_error_t           result   = cardano_multi_asset_get_keys(assets, &policies);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_write_start_array(writer, 2);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_write_signed_int(writer, cardano_value_get_coin(value));
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_write_start_map(writer, (int64_t)cardano_policy_id_list_get_length(policies));
  for (size_t i = 0U; result == CARDANO_SUCCESS && i < cardano_policy_id_list_get_length(policies); ++i)
  {
    cardano_blake2b_hash_t*   policy = NULL;
    cardano_asset_name_map_t* names  = NULL;
    result                           = cardano_policy_id_list_get(policies, i, &policy);
    if (result == CARDANO_SUCCESS)
      result = cardano_multi_asset_get_assets(assets, policy, &names);
    if (result == CARDANO_SUCCESS)
      result = cardano_blake2b_hash_to_cbor(policy, writer);
    if (result == CARDANO_SUCCESS)
      result = cardano_asset_name_map_to_cbor(names, writer);
    cardano_asset_name_map_unref(&names);
    cardano_blake2b_hash_unref(&policy);
  }
  cardano_policy_id_list_unref(&policies);
  cardano_multi_asset_unref(&assets);
  return result;
}

/* A clone must retain raw coin and descendant map state after mutation and
 * release of its source, not merely its normalized serialized asset value. */
unsigned int
cometa_test_raw_value_clone(const unsigned char* bytes, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
    return CARDANO_ERROR_POINTER_IS_NULL;
  *output                                = NULL;
  cardano_cbor_reader_t*    reader       = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_writer_t*    writer       = cardano_cbor_writer_new();
  cardano_multi_asset_t*    assets       = NULL;
  cardano_value_t*          source       = NULL;
  cardano_value_t*          copy         = NULL;
  cardano_policy_id_list_t* policies     = NULL;
  cardano_blake2b_hash_t*   first_policy = NULL;
  cardano_asset_name_map_t* names        = NULL;
  cardano_asset_name_t*     sentinel     = NULL;
  int64_t                   count = 0, coin = 0;
  size_t                    remaining = 0U;
  cardano_error_t           result    = reader == NULL || writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS && count != 2)
    result = CARDANO_ERROR_DECODING;
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_reader_read_int(reader, &coin);
  if (result == CARDANO_SUCCESS)
    result = cardano_multi_asset_from_cbor(reader, &assets);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_reader_read_end_array(reader);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  if (result == CARDANO_SUCCESS && remaining != 0U)
    result = CARDANO_ERROR_DECODING;
  if (result == CARDANO_SUCCESS)
    result = cardano_value_new(coin, assets, &source);
  if (result == CARDANO_SUCCESS)
    result = cardano_value_deep_clone(source, &copy);
  if (result == CARDANO_SUCCESS)
    result = cardano_value_set_coin(source, coin == 0 ? 1 : 0);
  if (result == CARDANO_SUCCESS)
    result = cardano_multi_asset_get_keys(assets, &policies);
  if (result == CARDANO_SUCCESS && cardano_policy_id_list_get_length(policies) > 0U)
  {
    result = cardano_policy_id_list_get(policies, 0U, &first_policy);
    if (result == CARDANO_SUCCESS)
      result = cardano_multi_asset_get_assets(assets, first_policy, &names);
    const byte_t sentinel_bytes[2] = { 0xff, 0xfe };
    if (result == CARDANO_SUCCESS)
      result = cardano_asset_name_from_bytes(sentinel_bytes, sizeof(sentinel_bytes), &sentinel);
    if (result == CARDANO_SUCCESS)
      result = cardano_asset_name_map_insert(names, sentinel, 123);
  }
  cardano_value_unref(&source);
  cardano_multi_asset_unref(&assets);
  if (result == CARDANO_SUCCESS)
    result = write_raw_value(copy, writer);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  if (result != CARDANO_SUCCESS)
    cardano_buffer_unref(output);
  cardano_asset_name_unref(&sentinel);
  cardano_asset_name_map_unref(&names);
  cardano_blake2b_hash_unref(&first_policy);
  cardano_policy_id_list_unref(&policies);
  cardano_value_unref(&copy);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}

/* Cache-state heuristic is deliberately checked separately from the encoded
 * input-tag observer: native returns true unconditionally after clearing. */
unsigned int
cometa_test_body_set_mode(const unsigned char* bytes, size_t size, unsigned int* before, unsigned int* after)
{
  if (before == NULL || after == NULL)
    return CARDANO_ERROR_POINTER_IS_NULL;
  *before                               = 0U;
  *after                                = 0U;
  cardano_cbor_reader_t*      reader    = cardano_cbor_reader_new(bytes, size);
  cardano_transaction_body_t* body      = NULL;
  cardano_error_t             result    = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_transaction_body_from_cbor(reader, &body);
  size_t                      remaining = 0U;
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  if (result == CARDANO_SUCCESS && remaining != 0U)
    result = CARDANO_ERROR_DECODING;
  if (result == CARDANO_SUCCESS)
  {
    *before = cardano_transaction_body_has_tagged_sets(body) ? 1U : 0U;
    cardano_transaction_body_clear_cbor_cache(body);
    *after = cardano_transaction_body_has_tagged_sets(body) ? 1U : 0U;
  }
  cardano_transaction_body_unref(&body);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
