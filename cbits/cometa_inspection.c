/**
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

#include "cometa_inspection.h"

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_inspection_compute(unsigned int operation, const unsigned char* input, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output = NULL;
  if (operation > 3U)
  {
    return CARDANO_ERROR_INVALID_ARGUMENT;
  }
  if (input == NULL && size != 0U)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  cardano_cbor_reader_t*          reader      = cardano_cbor_reader_new(input, size);
  cardano_json_writer_t*          writer      = cardano_json_writer_new(CARDANO_JSON_FORMAT_COMPACT);
  cardano_transaction_t*          transaction = NULL;
  cardano_sub_transaction_t*      sub         = NULL;
  cardano_transaction_body_t*     body        = NULL;
  cardano_sub_transaction_body_t* sub_body    = NULL;
  size_t                          remaining   = 0U;
  cardano_error_t                 result      = reader == NULL || writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;

  if (result == CARDANO_SUCCESS)
  {
    switch (operation)
    {
      case 0U:
        result = cardano_transaction_from_cbor(reader, &transaction);
        break;
      case 1U:
        result = cardano_sub_transaction_from_cbor(reader, &sub);
        break;
      case 2U:
        result = cardano_transaction_body_from_cbor(reader, &body);
        break;
      case 3U:
        result = cardano_sub_transaction_body_from_cbor(reader, &sub_body);
        break;
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
    if (result == CARDANO_SUCCESS && remaining != 0U)
    {
      result = CARDANO_ERROR_DECODING;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    switch (operation)
    {
      case 0U:
        result = cardano_transaction_to_cip116_json(transaction, writer);
        break;
      case 1U:
        result = cardano_sub_transaction_to_cip116_json(sub, writer);
        break;
      case 2U:
        result = cardano_transaction_body_to_cip116_json(body, writer);
        break;
      case 3U:
        result = cardano_sub_transaction_body_to_cip116_json(sub_body, writer);
        break;
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    /* Native JSON buffers contain their exact length, without a trailing NUL. */
    result = cardano_json_writer_encode_in_buffer(writer, output);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_buffer_unref(output);
    *output = NULL;
  }
  cardano_sub_transaction_body_unref(&sub_body);
  cardano_transaction_body_unref(&body);
  cardano_sub_transaction_unref(&sub);
  cardano_transaction_unref(&transaction);
  cardano_json_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
