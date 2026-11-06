/**
 * \file cometa_native_evaluation.c
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

#include "cometa_native_evaluation.h"
#include <cardano/cardano.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/* Each transport contains exactly one complete CBOR item. */
static cardano_error_t
finish_reader(cardano_cbor_reader_t* reader)
{
  size_t          remaining = 0;
  cardano_error_t result    = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  if (result == CARDANO_SUCCESS && remaining != 0)
  {
    result = CARDANO_ERROR_DECODING;
  }
  return result;
}

/* List insertion retains each child; local children and partial lists remain
 * independently owned and are released on every parse result. */
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
    cardano_utxo_t* child = NULL;
    result                = cardano_utxo_from_cbor(reader, &child);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_list_add(*output, child);
    }
    cardano_utxo_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_native_evaluation_run(uint64_t zero_time, uint64_t zero_slot, uint64_t slot_length, uint64_t protocol_major, unsigned int is_sub, uint64_t sub_index, const unsigned char* models, size_t models_size, const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, cardano_buffer_t** output, cardano_buffer_t** diagnostic)
{
  if (output != NULL)
  {
    *output = NULL;
  }
  if (diagnostic != NULL)
  {
    *diagnostic = NULL;
  }
  if (output == NULL || diagnostic == NULL || models == NULL || transaction == NULL || utxos == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  if (slot_length == 0)
  {
    return (unsigned int)CARDANO_ERROR_INVALID_ARGUMENT;
  }
  cardano_slot_config_t    slots         = { zero_time, zero_slot, slot_length };
  cardano_tx_evaluator_t*  evaluator     = NULL;
  cardano_transaction_t*   tx            = NULL;
  cardano_utxo_list_t*     additional    = NULL;
  cardano_costmdls_t*      costs         = NULL;
  cardano_redeemer_list_t* redeemers     = NULL;
  cardano_cbor_reader_t*   tx_reader     = cardano_cbor_reader_new(transaction, transaction_size);
  cardano_cbor_reader_t*   utxo_reader   = cardano_cbor_reader_new(utxos, utxos_size);
  cardano_cbor_reader_t*   models_reader = cardano_cbor_reader_new(models, models_size);
  cardano_cbor_writer_t*   writer        = cardano_cbor_writer_new();
  cardano_error_t          result        = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (tx_reader == NULL || utxo_reader == NULL || models_reader == NULL || writer == NULL)
  {
    goto cleanup;
  }
  result = cardano_transaction_from_cbor(tx_reader, &tx);
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(tx_reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(utxo_reader, &additional);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(utxo_reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_costmdls_from_cbor(models_reader, &costs);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(models_reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = is_sub == 0
      ? cardano_tx_evaluator_new_native(&slots, costs, protocol_major, &evaluator)
      : cardano_tx_evaluator_new_native_sub_transaction(&slots, costs, protocol_major, sub_index, &evaluator);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_tx_evaluator_evaluate(evaluator, tx, additional, &redeemers);
  }
  if (result == CARDANO_SUCCESS && redeemers == NULL)
  {
    result = CARDANO_ERROR_POINTER_IS_NULL;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_redeemer_list_to_cbor(redeemers, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
cleanup:
  if (result != CARDANO_SUCCESS)
  {
    const char* message = evaluator != NULL ? cardano_tx_evaluator_get_last_error(evaluator) : cardano_error_to_string(result);
    if (message == NULL || message[0] == '\0')
    {
      message = cardano_error_to_string(result);
    }
    *diagnostic = cardano_buffer_new_from((const byte_t*)message, strlen(message));
    cardano_buffer_unref(output);
    *output = NULL;
  }
  cardano_redeemer_list_unref(&redeemers);
  cardano_tx_evaluator_unref(&evaluator);
  cardano_costmdls_unref(&costs);
  cardano_utxo_list_unref(&additional);
  cardano_transaction_unref(&tx);
  cardano_cbor_reader_unref(&models_reader);
  cardano_cbor_reader_unref(&utxo_reader);
  cardano_cbor_reader_unref(&tx_reader);
  cardano_cbor_writer_unref(&writer);
  return (unsigned int)result;
}
