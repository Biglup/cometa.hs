/**
 * \file cometa_contextual_transaction.c
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

#include "cometa_contextual_transaction.h"
#include <cardano/cardano.h>

/* STATIC FUNCTIONS **********************************************************/

static cardano_error_t
finish_reader(cardano_cbor_reader_t* reader)
{
  size_t          remaining = 0U;
  cardano_error_t result    = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  return result == CARDANO_SUCCESS && remaining != 0U ? CARDANO_ERROR_DECODING : result;
}

static cardano_error_t
read_utxos(cardano_cbor_reader_t* reader, cardano_utxo_list_t** output)
{
  *output                = NULL;
  int64_t         size   = 0;
  cardano_error_t result = cardano_cbor_reader_read_start_array(reader, &size);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_utxo_list_new(output);
  }
  for (int64_t index = 0; result == CARDANO_SUCCESS; ++index)
  {
    cardano_cbor_reader_state_t state;
    result = cardano_cbor_reader_peek_state(reader, &state);
    if (result != CARDANO_SUCCESS || state == CARDANO_CBOR_READER_STATE_END_ARRAY)
    {
      break;
    }
    if (size >= 0 && index >= size)
    {
      result = CARDANO_ERROR_DECODING;
      break;
    }
    cardano_utxo_t* item = NULL;
    result               = cardano_utxo_from_cbor(reader, &item);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_list_add(*output, item);
    }
    cardano_utxo_unref(&item);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_contextual_certificate_index(const unsigned char* bytes, size_t size, const unsigned char* target, size_t target_size, uint64_t* index)
{
  if (index == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *index                                           = 0U;
  cardano_cbor_reader_t*             reader        = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_reader_t*             target_reader = cardano_cbor_reader_new(target, target_size);
  cardano_certificate_set_t*         certificates  = NULL;
  cardano_certificate_t*             certificate   = NULL;
  cardano_transaction_input_set_t*   inputs        = NULL;
  cardano_transaction_output_list_t* outputs       = NULL;
  cardano_transaction_body_t*        body          = NULL;
  cardano_witness_set_t*             witnesses     = NULL;
  cardano_transaction_t*             transaction   = NULL;
  cardano_error_t                    result        = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (reader == NULL || target_reader == NULL)
  {
    goto cleanup;
  }
  result = cardano_certificate_set_from_cbor(reader, &certificates);
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_certificate_from_cbor(target_reader, &certificate);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(target_reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_input_set_new(&inputs);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_output_list_new(&outputs);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_body_new(inputs, outputs, 0U, NULL, &body);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_body_set_certificates(body, certificates);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_witness_set_new(&witnesses);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_new(body, witnesses, NULL, &transaction);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_find_certificate_index(transaction, certificate, index);
  }
cleanup:
  cardano_transaction_unref(&transaction);
  cardano_witness_set_unref(&witnesses);
  cardano_transaction_body_unref(&body);
  cardano_transaction_output_list_unref(&outputs);
  cardano_transaction_input_set_unref(&inputs);
  cardano_certificate_unref(&certificate);
  cardano_certificate_set_unref(&certificates);
  cardano_cbor_reader_unref(&target_reader);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}

unsigned int
cometa_contextual_required_keys(const unsigned char* bytes, size_t size, const unsigned char* utxos, size_t utxos_size, cardano_buffer_t** output)
{
  if (output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output                                 = NULL;
  cardano_cbor_reader_t*      reader      = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_reader_t*      utxo_reader = cardano_cbor_reader_new(utxos, utxos_size);
  cardano_cbor_writer_t*      writer      = cardano_cbor_writer_new();
  cardano_transaction_t*      transaction = NULL;
  cardano_utxo_list_t*        resolved    = NULL;
  cardano_blake2b_hash_set_t* hashes      = NULL;
  cardano_error_t             result      = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (reader == NULL || utxo_reader == NULL || writer == NULL)
  {
    goto cleanup;
  }
  result = cardano_transaction_from_cbor(reader, &transaction);
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(utxo_reader, &resolved);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(utxo_reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_get_unique_signers(transaction, resolved, &hashes);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_blake2b_hash_set_to_cbor(hashes, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
cleanup:
  if (result != CARDANO_SUCCESS)
  {
    cardano_buffer_unref(output);
    *output = NULL;
  }
  cardano_blake2b_hash_set_unref(&hashes);
  cardano_utxo_list_unref(&resolved);
  cardano_transaction_unref(&transaction);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&utxo_reader);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
