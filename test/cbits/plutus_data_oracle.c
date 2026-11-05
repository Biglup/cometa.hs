/**
 * \file plutus_data_oracle.c
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

#include <cardano/cardano.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/* Getter outputs are owned references (integer extraction clones). Every local
 * reference is released before returning, including partial failure. Map keys
 * and values are inspected by parallel indexed lists so duplicates survive. */
static cardano_error_t inspect_data(cardano_plutus_data_t* data, uint64_t* counts);

static cardano_error_t
inspect_list(cardano_plutus_list_t* list, uint64_t* counts)
{
  cardano_error_t result = CARDANO_SUCCESS;
  for (size_t i = 0U; i < cardano_plutus_list_get_length(list); ++i)
  {
    cardano_plutus_data_t* child = NULL;
    result                       = cardano_plutus_list_get(list, i, &child);
    if (result == CARDANO_SUCCESS)
    {
      result = inspect_data(child, counts);
    }
    cardano_plutus_data_unref(&child);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  return result;
}

static cardano_error_t
inspect_data(cardano_plutus_data_t* data, uint64_t* counts)
{
  cardano_plutus_data_kind_t    kind;
  cardano_error_t               result      = cardano_plutus_data_get_kind(data, &kind);
  cardano_constr_plutus_data_t* constr      = NULL;
  cardano_plutus_list_t*        list        = NULL;
  cardano_plutus_list_t*        values      = NULL;
  cardano_plutus_map_t*         map         = NULL;
  cardano_bigint_t*             integer     = NULL;
  cardano_buffer_t*             bytes       = NULL;
  uint64_t                      alternative = 0U;
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  ++counts[kind];
  switch (kind)
  {
    case CARDANO_PLUTUS_DATA_KIND_CONSTR:
      result = cardano_plutus_data_to_constr(data, &constr);
      if (result == CARDANO_SUCCESS)
      {
        result     = cardano_constr_plutus_data_get_alternative(constr, &alternative);
        counts[5] += alternative;
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_constr_plutus_data_get_data(constr, &list);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = inspect_list(list, counts);
      }
      break;
    case CARDANO_PLUTUS_DATA_KIND_MAP:
      result = cardano_plutus_data_to_map(data, &map);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_plutus_map_get_keys(map, &list);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_plutus_map_get_values(map, &values);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = inspect_list(list, counts);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = inspect_list(values, counts);
      }
      break;
    case CARDANO_PLUTUS_DATA_KIND_LIST:
      result = cardano_plutus_data_to_list(data, &list);
      if (result == CARDANO_SUCCESS)
      {
        result = inspect_list(list, counts);
      }
      break;
    case CARDANO_PLUTUS_DATA_KIND_INTEGER:
      result = cardano_plutus_data_to_integer(data, &integer);
      if (result == CARDANO_SUCCESS)
      {
        counts[6] += cardano_bigint_bit_length(integer);
      }
      break;
    case CARDANO_PLUTUS_DATA_KIND_BYTES:
      result = cardano_plutus_data_to_bounded_bytes(data, &bytes);
      if (result == CARDANO_SUCCESS)
      {
        counts[7] += cardano_buffer_get_size(bytes);
      }
      break;
    default:
      result = CARDANO_ERROR_GENERIC;
      break;
  }
cleanup:
  cardano_buffer_unref(&bytes);
  cardano_bigint_unref(&integer);
  cardano_plutus_map_unref(&map);
  cardano_plutus_list_unref(&values);
  cardano_plutus_list_unref(&list);
  cardano_constr_plutus_data_unref(&constr);
  return result;
}

/* DEFINITIONS ***************************************************************/

/* Borrowed input/output spans last only for this synchronous call. First inspect
 * every typed node, then recursively invalidate original-encoding caches before
 * native reserialization; this exercises domain conversion beyond forwarding.
 * Output is caller-owned. No allocator replacement or native pointer escapes. */
unsigned int
cometa_test_plutus_data_oracle(const unsigned char* input, size_t input_size, unsigned char* output, size_t capacity, size_t* output_size, uint64_t* counts)
{
  cardano_cbor_reader_t* reader  = cardano_cbor_reader_new(input, input_size);
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_plutus_data_t* data    = NULL;
  cardano_buffer_t*      encoded = NULL;
  cardano_error_t        result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  memset(counts, 0, 8U * sizeof(uint64_t));
  if ((reader == NULL) || (writer == NULL))
  {
    goto cleanup;
  }
  result = cardano_plutus_data_from_cbor(reader, &data);
  if (result == CARDANO_SUCCESS)
  {
    result = inspect_data(data, counts);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_data_clear_cbor_cache(data);
    result = cardano_plutus_data_to_cbor(data, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  }
  if (result == CARDANO_SUCCESS)
  {
    *output_size = cardano_buffer_get_size(encoded);
    if (*output_size > capacity)
    {
      result = CARDANO_ERROR_GENERIC;
    }
    else
    {
      memcpy(output, cardano_buffer_get_data(encoded), *output_size);
    }
  }
cleanup:
  cardano_buffer_unref(&encoded);
  cardano_plutus_data_unref(&data);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
