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
