/**
 * \file cometa_reencode.c
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

#include "cometa_reencode.h"

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_reencode(unsigned int kind, const unsigned char* bytes, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
    return CARDANO_ERROR_POINTER_IS_NULL;
  *output                                   = NULL;
  cardano_cbor_reader_t*        reader      = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_writer_t*        writer      = cardano_cbor_writer_new();
  cardano_native_script_t*      script      = NULL;
  cardano_native_script_list_t* scripts     = NULL;
  cardano_transaction_t*        transaction = NULL;
  cardano_sub_transaction_t*    intent      = NULL;
  size_t                        remaining   = 0U;
  cardano_error_t               result      = reader == NULL || writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;
  if (result == CARDANO_SUCCESS)
  {
    switch (kind)
    {
      case 0U:
        result = cardano_native_script_from_cbor(reader, &script);
        break;
      case 1U:
        result = cardano_native_script_list_from_cbor(reader, &scripts);
        break;
      case 2U:
        result = cardano_transaction_from_cbor(reader, &transaction);
        break;
      case 3U:
        result = cardano_sub_transaction_from_cbor(reader, &intent);
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
      result = CARDANO_ERROR_DECODING;
  }
  if (result == CARDANO_SUCCESS)
  {
    switch (kind)
    {
      case 0U:
        cardano_native_script_clear_cbor_cache(script);
        result = cardano_native_script_to_cbor(script, writer);
        break;
      case 1U:
        cardano_native_script_list_clear_cbor_cache(scripts);
        result = cardano_native_script_list_to_cbor(scripts, writer);
        break;
      case 2U:
        cardano_transaction_clear_cbor_cache(transaction);
        result = cardano_transaction_to_cbor(transaction, writer);
        break;
      case 3U:
        cardano_sub_transaction_clear_cbor_cache(intent);
        result = cardano_sub_transaction_to_cbor(intent, writer);
        break;
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  if (result != CARDANO_SUCCESS)
    cardano_buffer_unref(output);
  cardano_native_script_unref(&script);
  cardano_native_script_list_unref(&scripts);
  cardano_transaction_unref(&transaction);
  cardano_sub_transaction_unref(&intent);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  return (unsigned int)result;
}
