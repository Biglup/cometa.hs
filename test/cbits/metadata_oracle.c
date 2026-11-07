/**
 * \file metadata_oracle.c
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

#include <cardano/auxiliary_data/metadatum.h>
#include <cardano/auxiliary_data/metadatum_list.h>
#include <cardano/auxiliary_data/metadatum_map.h>
#include <cardano/auxiliary_data/transaction_metadata.h>
#include <cardano/cbor/cbor_reader.h>
#include <cardano/cbor/cbor_writer.h>
#include <stdlib.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/**
 * \brief Rebuild every value through typed native getters and fresh constructors.
 * All getter outputs own one reference. Constructors retain or clone their
 * inputs; every local reference is independently released on all exits.
 */
static cardano_error_t
rebuild(cardano_metadatum_t* source, cardano_metadatum_t** output)
{
  cardano_metadatum_kind_t  kind;
  cardano_error_t           result      = cardano_metadatum_get_kind(source, &kind);
  cardano_metadatum_map_t*  map         = NULL;
  cardano_metadatum_map_t*  fresh_map   = NULL;
  cardano_metadatum_list_t* list        = NULL;
  cardano_metadatum_list_t* fresh_list  = NULL;
  cardano_metadatum_t*      key         = NULL;
  cardano_metadatum_t*      value       = NULL;
  cardano_metadatum_t*      fresh_key   = NULL;
  cardano_metadatum_t*      fresh_value = NULL;
  cardano_bigint_t*         integer     = NULL;
  cardano_buffer_t*         bytes       = NULL;
  char                      text[65]    = { 0 };

  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  switch (kind)
  {
    case CARDANO_METADATUM_KIND_INTEGER:
      result = cardano_metadatum_to_integer(source, &integer);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_metadatum_new_integer(integer, output);
      }
      break;
    case CARDANO_METADATUM_KIND_BYTES:
      result = cardano_metadatum_to_bounded_bytes(source, &bytes);
      if (result == CARDANO_SUCCESS)
      {
        static const unsigned char empty = 0;
        const unsigned char*       data  = cardano_buffer_get_data(bytes);
        size_t                     size  = cardano_buffer_get_size(bytes);
        result                           = cardano_metadatum_new_bytes(size == 0 ? &empty : data, size, output);
      }
      break;
    case CARDANO_METADATUM_KIND_TEXT:
    {
      size_t size = cardano_metadatum_get_string_size(source);
      if ((size == 0) || (size > sizeof(text)))
      {
        result = CARDANO_ERROR_OUT_OF_BOUNDS_MEMORY_READ;
        break;
      }
      result = cardano_metadatum_to_string(source, text, sizeof(text));
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_metadatum_new_string(text, size - 1, output);
      }
      break;
    }
    case CARDANO_METADATUM_KIND_LIST:
      result = cardano_metadatum_to_list(source, &list);
      if (result != CARDANO_SUCCESS)
      {
        break;
      }
      result = cardano_metadatum_list_new(&fresh_list);
      if (result != CARDANO_SUCCESS)
      {
        break;
      }
      for (size_t index = 0; index < cardano_metadatum_list_get_length(list); ++index)
      {
        result = cardano_metadatum_list_get(list, index, &value);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild(value, &fresh_value);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_metadatum_list_add(fresh_list, fresh_value);
        }
        cardano_metadatum_unref(&value);
        value = NULL;
        cardano_metadatum_unref(&fresh_value);
        fresh_value = NULL;
        if (result != CARDANO_SUCCESS)
        {
          goto cleanup;
        }
      }
      result = cardano_metadatum_new_list(fresh_list, output);
      break;
    case CARDANO_METADATUM_KIND_MAP:
      result = cardano_metadatum_to_map(source, &map);
      if (result != CARDANO_SUCCESS)
      {
        break;
      }
      result = cardano_metadatum_map_new(&fresh_map);
      if (result != CARDANO_SUCCESS)
      {
        break;
      }
      for (size_t index = 0; index < cardano_metadatum_map_get_length(map); ++index)
      {
        result = cardano_metadatum_map_get_at(map, index, &key, &value);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild(key, &fresh_key);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild(value, &fresh_value);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_metadatum_map_insert(fresh_map, fresh_key, fresh_value);
        }
        cardano_metadatum_unref(&key);
        key = NULL;
        cardano_metadatum_unref(&value);
        value = NULL;
        cardano_metadatum_unref(&fresh_key);
        fresh_key = NULL;
        cardano_metadatum_unref(&fresh_value);
        fresh_value = NULL;
        if (result != CARDANO_SUCCESS)
        {
          goto cleanup;
        }
      }
      result = cardano_metadatum_new_map(fresh_map, output);
      break;
    default:
      result = CARDANO_ERROR_DECODING;
      break;
  }

cleanup:
  cardano_metadatum_unref(&key);
  key = NULL;
  cardano_metadatum_unref(&value);
  value = NULL;
  cardano_metadatum_unref(&fresh_key);
  fresh_key = NULL;
  cardano_metadatum_unref(&fresh_value);
  fresh_value = NULL;
  cardano_metadatum_list_unref(&list);
  cardano_metadatum_list_unref(&fresh_list);
  cardano_metadatum_map_unref(&map);
  cardano_metadatum_map_unref(&fresh_map);
  cardano_bigint_unref(&integer);
  cardano_buffer_unref(&bytes);

  return result;
}

/* DEFINITIONS ***************************************************************/

/**
 * \brief Compare a normalized Haskell encoding with the pinned native codec.
 * \param input Borrowed bytes, valid through this synchronous call.
 * \param size Input byte count.
 * \param transaction Nonzero for transaction metadata, zero for one metadatum.
 * \return One on agreement, zero on failure. All outputs and partial failures
 * are operation-owned and released before return; no reference escapes.
 */
int
cometa_test_metadata_agreement(const unsigned char* input, size_t size, int transaction)
{
  cardano_cbor_reader_t*          reader         = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t*          writer         = cardano_cbor_writer_new();
  cardano_metadatum_t*            value          = NULL;
  cardano_metadatum_t*            fresh_value    = NULL;
  cardano_transaction_metadata_t* fresh_metadata = NULL;
  cardano_transaction_metadata_t* metadata       = NULL;
  unsigned char*                  output         = NULL;
  int                             agrees         = 0;
  if ((reader == NULL) || (writer == NULL))
  {
    goto cleanup;
  }
  cardano_error_t result;
  if (transaction)
  {
    result = cardano_transaction_metadata_from_cbor(reader, &metadata);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
    result = cardano_transaction_metadata_new(&fresh_metadata);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
    for (size_t index = 0; index < cardano_transaction_metadata_get_length(metadata); ++index)
    {
      uint64_t label = 0;
      result         = cardano_transaction_metadata_get_key_value_at(metadata, index, &label, &value);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild(value, &fresh_value);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_transaction_metadata_insert(fresh_metadata, label, fresh_value);
      }
      cardano_metadatum_unref(&value);
      value = NULL;
      cardano_metadatum_unref(&fresh_value);
      fresh_value = NULL;
      if (result != CARDANO_SUCCESS)
      {
        goto cleanup;
      }
    }
    result = cardano_transaction_metadata_to_cbor(fresh_metadata, writer);
  }
  else
  {
    result = cardano_metadatum_from_cbor(reader, &value);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
    result = rebuild(value, &fresh_value);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
    result = cardano_metadatum_to_cbor(fresh_value, writer);
  }
  if ((result != CARDANO_SUCCESS) || (cardano_cbor_writer_get_encode_size(writer) != size))
  {
    goto cleanup;
  }
  output = malloc(size);
  if (output == NULL)
  {
    goto cleanup;
  }
  result = cardano_cbor_writer_encode(writer, output, size);
  agrees = (result == CARDANO_SUCCESS) && (memcmp(input, output, size) == 0);
cleanup:
  free(output);
  cardano_metadatum_unref(&value);
  value = NULL;
  cardano_metadatum_unref(&fresh_value);
  fresh_value = NULL;
  cardano_transaction_metadata_unref(&metadata);
  cardano_transaction_metadata_unref(&fresh_metadata);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  return agrees;
}

/**
 * \brief Checks plain JSON input/output against typed metadatum CBOR.
 * Input spans are borrowed. JSON allocation and every acquired native owner
 * are scoped and released on all exits. JSON parsing reads semantic fields.
 */
int
cometa_test_metadata_plain_json(const char* json, size_t json_size, const unsigned char* expected, size_t size)
{
  cardano_metadatum_t*   datum     = NULL;
  cardano_metadatum_t*   roundtrip = NULL;
  cardano_cbor_writer_t* writer    = cardano_cbor_writer_new();
  cardano_buffer_t*      encoded   = NULL;
  char*                  output    = NULL;
  cardano_error_t        result    = cardano_metadatum_from_json(json, json_size, &datum);
  if (writer == NULL)
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (result == CARDANO_SUCCESS)
  {
    size_t output_size = cardano_metadatum_get_json_size(datum);
    output             = malloc(output_size);
    if (output == NULL)
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    if (result == CARDANO_SUCCESS)
      result = cardano_metadatum_to_json(datum, output, output_size);
    if (result == CARDANO_SUCCESS)
      result = cardano_metadatum_from_json(output, strlen(output), &roundtrip);
  }
  if (result == CARDANO_SUCCESS)
    result = cardano_metadatum_to_cbor(roundtrip, writer);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  int agrees = 0;
  if (result == CARDANO_SUCCESS)
    agrees = (cardano_buffer_get_size(encoded) == size) && (memcmp(cardano_buffer_get_data(encoded), expected, size) == 0);
  free(output);
  cardano_buffer_unref(&encoded);
  cardano_cbor_writer_unref(&writer);
  cardano_metadatum_unref(&roundtrip);
  cardano_metadatum_unref(&datum);
  return agrees;
}
