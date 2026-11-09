/**
 * \file cometa_cbor.c
 *
 * \author angel.castillo
 * \date   Nov 04, 2026
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

#include "cometa_cbor.h"

#include <cardano/cbor/cbor_writer.h>
#include <limits.h>
#include <stdio.h>

/* STATIC FUNCTIONS **********************************************************/

/**
 * \brief Copies a bounded diagnostic without transferring native string ownership.
 */
static void
copy_error(char* error, size_t capacity, const char* message)
{
  if ((error != NULL) && (capacity > 0U))
  {
    (void)snprintf(error, capacity, "%s", message);
  }
}

/**
 * \brief Copies a reader-local failure before its owner can be released.
 */
static unsigned int
reader_status(cardano_cbor_reader_t* reader, cardano_error_t result, char* error, size_t capacity)
{
  if (result != CARDANO_SUCCESS)
  {
    const char* message = cardano_cbor_reader_get_last_error(reader);
    copy_error(error, capacity, message[0] == '\0' ? cardano_error_to_string(result) : message);
  }

  return (unsigned int)result;
}

/**
 * \brief Encodes an owned result if writing succeeded, then releases the writer on every path.
 */
static unsigned int
finish_writer(cardano_cbor_writer_t* writer, cardano_error_t result, cardano_buffer_t** output, char* error, size_t capacity)
{
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }

  if (result != CARDANO_SUCCESS)
  {
    const char* message = cardano_cbor_writer_get_last_error(writer);
    copy_error(error, capacity, message[0] == '\0' ? cardano_error_to_string(result) : message);
  }

  cardano_cbor_writer_unref(&writer);

  return (unsigned int)result;
}

/**
 * \brief Allocates a scoped writer and initializes the caller's owned-result slot.
 */
static cardano_cbor_writer_t*
new_writer(cardano_buffer_t** output, char* error, size_t capacity)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();

  if (writer == NULL)
  {
    copy_error(error, capacity, "Failed to allocate CBOR writer.");
  }

  return writer;
}

/**
 * \brief Requires the reader to have consumed the entire input after one item.
 */
static cardano_error_t
require_finished(cardano_cbor_reader_t* reader)
{
  size_t          remaining = 0U;
  cardano_error_t result    = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);

  if ((result == CARDANO_SUCCESS) && (remaining != 0U))
  {
    cardano_cbor_reader_set_last_error(reader, "Trailing bytes after one CBOR item.");
    return CARDANO_ERROR_DECODING;
  }

  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_cbor_reader_new(const unsigned char* data, size_t size, cardano_cbor_reader_t** output, char* error, size_t error_size)
{
  *output = NULL;

  if (size == 0U)
  {
    copy_error(error, error_size, "CBOR input is empty.");
    return CARDANO_ERROR_DECODING;
  }

  *output = cardano_cbor_reader_new(data, size);

  if (*output == NULL)
  {
    copy_error(error, error_size, "Failed to allocate CBOR reader.");
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  return CARDANO_SUCCESS;
}

unsigned int
cometa_cbor_validate(const unsigned char* data, size_t size, char* error, size_t error_size)
{
  cardano_cbor_reader_t* reader = NULL;
  unsigned int           result = cometa_cbor_reader_new(data, size, &reader, error, error_size);

  if (result != CARDANO_SUCCESS)
  {
    return result;
  }

  cardano_error_t status = cardano_cbor_reader_skip_value(reader);

  if (status == CARDANO_SUCCESS)
  {
    status = require_finished(reader);
  }

  result = reader_status(reader, status, error, error_size);
  cardano_cbor_reader_unref(&reader);

  return result;
}

unsigned int
cometa_cbor_encode_integer(int negative, uint64_t argument, cardano_buffer_t** output, char* error, size_t error_size)
{
  cardano_cbor_writer_t* writer = new_writer(output, error, error_size);

  if (writer == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  cardano_error_t result = negative != 0 ? cardano_cbor_writer_write_negative_int(writer, argument) : cardano_cbor_writer_write_uint(writer, argument);

  return finish_writer(writer, result, output, error, error_size);
}

unsigned int
cometa_cbor_decode_integer(const unsigned char* data, size_t size, int* negative, uint64_t* argument, char* error, size_t error_size)
{
  cardano_cbor_reader_t* reader = NULL;
  unsigned int           result = cometa_cbor_reader_new(data, size, &reader, error, error_size);

  if (result != CARDANO_SUCCESS)
  {
    return result;
  }

  cardano_cbor_reader_state_t state  = CARDANO_CBOR_READER_STATE_UNDEFINED;
  cardano_error_t             status = cardano_cbor_reader_peek_state(reader, &state);
  *negative                          = state == CARDANO_CBOR_READER_STATE_NEGATIVE_INTEGER ? 1 : 0;

  if (status == CARDANO_SUCCESS)
  {
    status = *negative != 0 ? cardano_cbor_reader_read_negative_int(reader, argument) : cardano_cbor_reader_read_uint(reader, argument);
  }

  if (status == CARDANO_SUCCESS)
  {
    status = require_finished(reader);
  }

  result = reader_status(reader, status, error, error_size);
  cardano_cbor_reader_unref(&reader);

  return result;
}

unsigned int
cometa_cbor_encode_string(int text, const unsigned char* data, size_t size, cardano_buffer_t** output, char* error, size_t error_size)
{
  cardano_cbor_writer_t* writer = new_writer(output, error, error_size);

  if (writer == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  cardano_error_t result = text != 0 ? cardano_cbor_writer_write_textstring(writer, (const char*)data, size) : cardano_cbor_writer_write_bytestring(writer, data, size);

  return finish_writer(writer, result, output, error, error_size);
}

unsigned int
cometa_cbor_decode_string(int text, const unsigned char* data, size_t size, cardano_buffer_t** output, char* error, size_t error_size)
{
  *output = NULL;

  cardano_cbor_reader_t* reader = NULL;
  unsigned int           result = cometa_cbor_reader_new(data, size, &reader, error, error_size);

  if (result != CARDANO_SUCCESS)
  {
    return result;
  }

  cardano_error_t status = text != 0 ? cardano_cbor_reader_read_textstring(reader, output) : cardano_cbor_reader_read_bytestring(reader, output);
  result                 = reader_status(reader, status, error, error_size);
  cardano_cbor_reader_unref(&reader);

  return result;
}

unsigned int
cometa_cbor_encode_bool(int value, cardano_buffer_t** output, char* error, size_t error_size)
{
  cardano_cbor_writer_t* writer = new_writer(output, error, error_size);

  if (writer == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  cardano_error_t result = cardano_cbor_writer_write_bool(writer, value != 0);

  return finish_writer(writer, result, output, error, error_size);
}

unsigned int
cometa_cbor_decode_bool(const unsigned char* data, size_t size, int* value, char* error, size_t error_size)
{
  cardano_cbor_reader_t* reader = NULL;
  unsigned int           result = cometa_cbor_reader_new(data, size, &reader, error, error_size);

  if (result != CARDANO_SUCCESS)
  {
    return result;
  }

  bool            native = false;
  cardano_error_t status = cardano_cbor_reader_read_bool(reader, &native);
  *value                 = native ? 1 : 0;
  result                 = reader_status(reader, status, error, error_size);
  cardano_cbor_reader_unref(&reader);

  return result;
}

unsigned int
cometa_cbor_encode_undefined(cardano_buffer_t** output, char* error, size_t error_size)
{
  cardano_cbor_writer_t* writer = new_writer(output, error, error_size);

  if (writer == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  return finish_writer(writer, cardano_cbor_writer_write_undefined(writer), output, error, error_size);
}

unsigned int
cometa_cbor_decode_double(const unsigned char* data, size_t size, double* value, char* error, size_t error_size)
{
  cardano_cbor_reader_t* reader = NULL;
  unsigned int           result = cometa_cbor_reader_new(data, size, &reader, error, error_size);

  if (result != CARDANO_SUCCESS)
  {
    return result;
  }

  cardano_error_t status = cardano_cbor_reader_read_double(reader, value);
  if (status == CARDANO_SUCCESS)
  {
    status = require_finished(reader);
  }
  result = reader_status(reader, status, error, error_size);
  cardano_cbor_reader_unref(&reader);

  return result;
}

unsigned int
cometa_cbor_decode_simple(const unsigned char* data, size_t size, uint8_t* value, char* error, size_t error_size)
{
  cardano_cbor_reader_t* reader = NULL;
  unsigned int           result = cometa_cbor_reader_new(data, size, &reader, error, error_size);

  if (result != CARDANO_SUCCESS)
  {
    return result;
  }

  cardano_cbor_simple_value_t native = CARDANO_CBOR_SIMPLE_VALUE_UNDEFINED;
  cardano_error_t             status = cardano_cbor_reader_read_simple_value(reader, &native);
  if (status == CARDANO_SUCCESS)
  {
    status = require_finished(reader);
    *value = (uint8_t)native;
  }
  result = reader_status(reader, status, error, error_size);
  cardano_cbor_reader_unref(&reader);

  return result;
}

unsigned int
cometa_cbor_encode_collection(int map, size_t count, const unsigned char* data, size_t size, cardano_buffer_t** output, char* error, size_t error_size)
{
  *output = NULL;

  if (count > INT64_MAX)
  {
    copy_error(error, error_size, "CBOR collection length exceeds the native bound.");
    return CARDANO_ERROR_INTEGER_OVERFLOW;
  }

  cardano_cbor_writer_t* writer = new_writer(output, error, error_size);

  if (writer == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  cardano_error_t result = map != 0 ? cardano_cbor_writer_write_start_map(writer, (int64_t)count) : cardano_cbor_writer_write_start_array(writer, (int64_t)count);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_encoded(writer, data, size);
  }

  // Definite collections have no trailing break; native end writers always emit one.
  return finish_writer(writer, result, output, error, error_size);
}

unsigned int
cometa_cbor_collection_start(cardano_cbor_reader_t* reader, int map, char* error, size_t error_size)
{
  int64_t         length = 0;
  cardano_error_t result = map != 0 ? cardano_cbor_reader_read_start_map(reader, &length) : cardano_cbor_reader_read_start_array(reader, &length);

  return reader_status(reader, result, error, error_size);
}

unsigned int
cometa_cbor_collection_at_end(cardano_cbor_reader_t* reader, int map, int* at_end, char* error, size_t error_size)
{
  cardano_cbor_reader_state_t state  = CARDANO_CBOR_READER_STATE_UNDEFINED;
  cardano_error_t             result = cardano_cbor_reader_peek_state(reader, &state);
  *at_end                            = state == (map != 0 ? CARDANO_CBOR_READER_STATE_END_MAP : CARDANO_CBOR_READER_STATE_END_ARRAY) ? 1 : 0;

  return reader_status(reader, result, error, error_size);
}

unsigned int
cometa_cbor_collection_end(cardano_cbor_reader_t* reader, int map, char* error, size_t error_size)
{
  cardano_error_t result = map != 0 ? cardano_cbor_reader_read_end_map(reader) : cardano_cbor_reader_read_end_array(reader);

  if (result == CARDANO_SUCCESS)
  {
    result = require_finished(reader);
  }

  return reader_status(reader, result, error, error_size);
}

unsigned int
cometa_cbor_read_item(cardano_cbor_reader_t* reader, cardano_buffer_t** output, char* error, size_t error_size)
{
  *output = NULL;

  return reader_status(reader, cardano_cbor_reader_read_encoded_value(reader, output), error, error_size);
}

unsigned int
cometa_cbor_reader_remaining(cardano_cbor_reader_t* reader, size_t* remaining, char* error, size_t error_size)
{
  return reader_status(reader, cardano_cbor_reader_get_bytes_remaining(reader, remaining), error, error_size);
}

unsigned int
cometa_cbor_read_text_chunk(cardano_cbor_reader_t* reader, cardano_buffer_t** output, char* error, size_t error_size)
{
  *output = NULL;

  cardano_cbor_reader_state_t state  = CARDANO_CBOR_READER_STATE_UNDEFINED;
  cardano_error_t             result = cardano_cbor_reader_peek_state(reader, &state);

  if ((result == CARDANO_SUCCESS) && (state != CARDANO_CBOR_READER_STATE_TEXTSTRING))
  {
    cardano_cbor_reader_set_last_error(reader, "An indefinite text chunk must be a definite text string.");
    result = CARDANO_ERROR_DECODING;
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_encoded_value(reader, output);
  }

  return reader_status(reader, result, error, error_size);
}

void
cometa_cbor_reader_unref(cardano_cbor_reader_t** reader)
{
  cardano_cbor_reader_unref(reader);
}

void
cometa_cbor_buffer_unref(cardano_buffer_t** buffer)
{
  cardano_buffer_unref(buffer);
}

const unsigned char*
cometa_cbor_buffer_data(const cardano_buffer_t* buffer)
{
  return cardano_buffer_get_data(buffer);
}

size_t
cometa_cbor_buffer_size(const cardano_buffer_t* buffer)
{
  return cardano_buffer_get_size(buffer);
}
