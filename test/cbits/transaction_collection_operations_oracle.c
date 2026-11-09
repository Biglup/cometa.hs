/**
 * \file transaction_collection_operations_oracle.c
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

/* Reader/writer inputs are borrowed only through return. Each getter is an owned
 * retained reference; loop slots are cleared after non-nulling unref. */
static cardano_error_t
complete(cardano_cbor_reader_t* reader)
{
  size_t          remaining = 0U;
  cardano_error_t result    = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  return result == CARDANO_SUCCESS && remaining != 0U ? CARDANO_ERROR_DECODING : result;
}

static cardano_error_t
read_list(cardano_cbor_reader_t* reader, cardano_utxo_list_t** output)
{
  cardano_utxo_list_t* list   = NULL;
  cardano_utxo_t*      item   = NULL;
  int64_t              count  = 0;
  cardano_error_t      result = cardano_utxo_list_new(&list);
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  TRY(cardano_cbor_reader_read_start_array(reader, &count));
  if (count < 0)
  {
    result = CARDANO_ERROR_DECODING;
    goto cleanup;
  }
  for (int64_t i = 0; i < count; ++i)
  {
    TRY(cardano_utxo_from_cbor(reader, &item));
    TRY(cardano_utxo_list_add(list, item));
    cardano_utxo_unref(&item);
    item = NULL;
  }
  TRY(cardano_cbor_reader_read_end_array(reader));
  TRY(complete(reader));
  *output = list;
  list    = NULL;
cleanup:
  cardano_utxo_unref(&item);
  cardano_utxo_list_unref(&list);
  return result;
}

static cardano_error_t
write_list(cardano_utxo_list_t* list, cardano_cbor_writer_t* writer)
{
  cardano_utxo_t*        item   = NULL;
  cardano_cbor_writer_t* child  = NULL;
  cardano_buffer_t*      bytes  = NULL;
  cardano_error_t        result = cardano_cbor_writer_write_start_array(writer, (int64_t)cardano_utxo_list_get_length(list));
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  for (size_t i = 0; i < cardano_utxo_list_get_length(list); ++i)
  {
    TRY(cardano_utxo_list_get(list, i, &item));
    child = cardano_cbor_writer_new();
    if (child == NULL)
    {
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
      goto cleanup;
    }
    TRY(cardano_utxo_to_cbor(item, child));
    TRY(cardano_cbor_writer_encode_in_buffer(child, &bytes));
    TRY(cardano_cbor_writer_write_bytestring(writer, cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes)));
    cardano_buffer_unref(&bytes);
    bytes = NULL;
    cardano_cbor_writer_unref(&child);
    child = NULL;
    cardano_utxo_unref(&item);
    item = NULL;
  }
cleanup:
  cardano_buffer_unref(&bytes);
  cardano_cbor_writer_unref(&child);
  cardano_utxo_unref(&item);
  return result;
}

/* Copy encoded child bytes while their writer/buffer owners remain in scope. */
static cardano_error_t
write_script(cardano_script_t* script, cardano_cbor_writer_t* writer)
{
  if (script == NULL)
    return cardano_cbor_writer_write_null(writer);
  cardano_cbor_writer_t* child  = cardano_cbor_writer_new();
  cardano_buffer_t*      bytes  = NULL;
  cardano_error_t        result = child == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;
  if (result != CARDANO_SUCCESS)
    goto cleanup;
  TRY(cardano_script_to_cbor(script, child));
  TRY(cardano_cbor_writer_encode_in_buffer(child, &bytes));
  TRY(cardano_cbor_writer_write_bytestring(writer, cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes)));
cleanup:
  cardano_buffer_unref(&bytes);
  cardano_cbor_writer_unref(&child);
  return result;
}

/* DEFINITIONS ***************************************************************/

/* Operations: 0 slice [start,end), 1 erase start/count, 2 remove first equal UTxO.
 * Response [success, retained source, optional returned segment]. Native NULL
 * bounds results remain observable, including empty slice and empty-source erase.
 * The source is destroyed before serializing returned items, checking that slice
 * retains references and erase transfers them to the removed-list owner. */
int
cometa_test_transaction_collection_list(unsigned int operation, int64_t start, uint64_t end_or_count, const unsigned char* input, size_t input_size, const unsigned char* target, size_t target_size, unsigned char* output, size_t capacity, size_t* output_size)
{
  cardano_cbor_reader_t* reader        = cardano_cbor_reader_new(input, input_size);
  cardano_cbor_reader_t* target_reader = NULL;
  cardano_cbor_writer_t* writer        = cardano_cbor_writer_new();
  cardano_utxo_list_t*   source        = NULL;
  cardano_utxo_list_t*   segment       = NULL;
  cardano_utxo_t*        removing      = NULL;
  bool                   success       = false;
  cardano_error_t        result        = CARDANO_ERROR_INVALID_ARGUMENT;
  if (output_size == NULL)
    goto cleanup;
  *output_size = 0U;
  if (reader == NULL || writer == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  if (operation > 2U)
    goto cleanup;
  TRY(read_list(reader, &source));
  if (operation == 2U)
  {
    target_reader = cardano_cbor_reader_new(target, target_size);
    if (target_reader == NULL)
    {
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
      goto cleanup;
    }
    TRY(cardano_utxo_from_cbor(target_reader, &removing));
    TRY(complete(target_reader));
    TRY(cardano_utxo_list_remove(source, removing));
    success = true;
  }
  else if (end_or_count <= SIZE_MAX)
  {
    if (operation == 0U && start >= 0 && (uint64_t)start <= SIZE_MAX)
      segment = cardano_utxo_list_slice(source, (size_t)start, (size_t)end_or_count);
    else if (operation == 1U)
      segment = cardano_utxo_list_erase(source, start, (size_t)end_or_count);
    success = segment != NULL;
  }
  TRY(cardano_cbor_writer_write_start_array(writer, 3));
  TRY(cardano_cbor_writer_write_bool(writer, success));
  TRY(write_list(source, writer));
  cardano_utxo_list_unref(&source);
  source = NULL;
  if (segment == NULL)
    TRY(cardano_cbor_writer_write_null(writer));
  else
    TRY(write_list(segment, writer));
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_utxo_unref(&removing);
  cardano_utxo_list_unref(&segment);
  cardano_utxo_list_unref(&source);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_reader_unref(&target_reader);
  cardano_cbor_writer_unref(&writer);
  return (int)result;
}

/* Operations: 0 observe, 1 replace (empty replacement clears), 2 self-assign.
 * Retained old/new getters survive parent destruction; the replacement's local
 * reference is released immediately after set, proving that the setter retains.
 * Response [old script CBOR or null, new output bytes, new script CBOR or null]. */
int
cometa_test_transaction_collection_script(unsigned int operation, const unsigned char* input, size_t input_size, const unsigned char* replacement_bytes, size_t replacement_size, unsigned char* output, size_t capacity, size_t* output_size)
{
  cardano_cbor_reader_t*        reader         = cardano_cbor_reader_new(input, input_size);
  cardano_cbor_reader_t*        script_reader  = NULL;
  cardano_cbor_writer_t*        writer         = cardano_cbor_writer_new();
  cardano_cbor_writer_t*        child          = cardano_cbor_writer_new();
  cardano_buffer_t*             encoded_output = NULL;
  cardano_transaction_output_t* value          = NULL;
  cardano_script_t*             old_script     = NULL;
  cardano_script_t*             new_script     = NULL;
  cardano_script_t*             replacement    = NULL;
  cardano_error_t               result         = CARDANO_ERROR_INVALID_ARGUMENT;
  if (output_size == NULL)
    goto cleanup;
  *output_size = 0U;
  if (reader == NULL || writer == NULL || child == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  if (operation > 2U)
    goto cleanup;
  TRY(cardano_transaction_output_from_cbor(reader, &value));
  TRY(complete(reader));
  old_script = cardano_transaction_output_get_script_ref(value);
  if (operation == 1U)
  {
    if (replacement_size != 0U)
    {
      script_reader = cardano_cbor_reader_new(replacement_bytes, replacement_size);
      if (script_reader == NULL)
      {
        result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
        goto cleanup;
      }
      TRY(cardano_script_from_cbor(script_reader, &replacement));
      TRY(complete(script_reader));
    }
    TRY(cardano_transaction_output_set_script_ref(value, replacement));
    cardano_script_unref(&replacement);
    replacement = NULL;
  }
  if (operation == 2U)
    TRY(cardano_transaction_output_set_script_ref(value, old_script));
  new_script = cardano_transaction_output_get_script_ref(value);
  TRY(cardano_transaction_output_to_cbor(value, child));
  TRY(cardano_cbor_writer_encode_in_buffer(child, &encoded_output));
  cardano_transaction_output_unref(&value);
  value = NULL;
  TRY(cardano_cbor_writer_write_start_array(writer, 3));
  TRY(write_script(old_script, writer));
  TRY(cardano_cbor_writer_write_bytestring(writer, cardano_buffer_get_data(encoded_output), cardano_buffer_get_size(encoded_output)));
  TRY(write_script(new_script, writer));
  *output_size = cardano_cbor_writer_get_encode_size(writer);
  TRY(cardano_cbor_writer_encode(writer, output, capacity));
cleanup:
  cardano_script_unref(&old_script);
  cardano_script_unref(&new_script);
  cardano_script_unref(&replacement);
  cardano_transaction_output_unref(&value);
  cardano_buffer_unref(&encoded_output);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_reader_unref(&script_reader);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_writer_unref(&child);
  return (int)result;
}

#undef TRY
