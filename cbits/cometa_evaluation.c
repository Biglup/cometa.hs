/**
 * \file cometa_evaluation.c
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
#include "cometa_evaluation.h"
#include "cometa_provider_runtime.h"
#include <cardano/cardano.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

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

/* Indexed UTxO getters retain children. Null additional UTxOs serialize as []. */
static cardano_error_t
write_utxos(cardano_cbor_writer_t* writer, cardano_utxo_list_t* values)
{
  size_t          count  = cardano_utxo_list_get_length(values);
  cardano_error_t result = cardano_cbor_writer_write_start_array(writer, (int64_t)count);
  for (size_t index = 0; result == CARDANO_SUCCESS && index < count; ++index)
  {
    cardano_utxo_t* child = NULL;
    result                = cardano_utxo_list_get(values, index, &child);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_to_cbor(child, writer);
    }
    cardano_utxo_unref(&child);
  }
  return result;
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

/* Inputs borrow for the synchronous callback. Dispatch roots and joins Haskell
 * workers; reply parsing completes before transferring one owned redeemer list. */
static cardano_error_t
evaluate_callback(cardano_tx_evaluator_impl_t* impl, cardano_transaction_t* transaction, cardano_utxo_list_t* additional, cardano_redeemer_list_t** output)
{
  *output                        = NULL;
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader  = NULL;
  cardano_buffer_t*      request = NULL;
  cardano_buffer_t*      reply   = NULL;
  cardano_error_t        result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (writer == NULL)
  {
    goto cleanup;
  }
  result = cardano_cbor_writer_write_start_array(writer, 2);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_to_cbor(transaction, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = write_utxos(writer, additional);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &request);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_runtime_dispatch((cometa_runtime_t*)impl->context, 100, cardano_buffer_get_data(request), cardano_buffer_get_size(request), &reply, impl->error_message, sizeof(impl->error_message));
  }
  if (result == CARDANO_SUCCESS && reply == NULL)
  {
    result = CARDANO_ERROR_POINTER_IS_NULL;
  }
  if (result == CARDANO_SUCCESS)
  {
    reader = cardano_cbor_reader_new(cardano_buffer_get_data(reply), cardano_buffer_get_size(reply));
    if (reader == NULL)
    {
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_redeemer_list_from_cbor(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = finish_reader(reader);
  }
cleanup:
  if (result != CARDANO_SUCCESS)
  {
    cardano_redeemer_list_unref(output);
    *output = NULL;
  }
  cardano_cbor_reader_unref(&reader);
  cardano_buffer_unref(&reply);
  cardano_buffer_unref(&request);
  cardano_cbor_writer_unref(&writer);
  return result;
}

/* DEFINITIONS ***************************************************************/
unsigned int
cometa_evaluation_new(cometa_runtime_t* runtime, cardano_tx_evaluator_t** output)
{
  if (output != NULL)
  {
    *output = NULL;
  }
  if (runtime == NULL || output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  cardano_tx_evaluator_impl_t impl = { 0 };
  memcpy(impl.name, "Cometa evaluator", sizeof("Cometa evaluator"));
  impl.context  = cometa_runtime_object(runtime);
  impl.evaluate = evaluate_callback;
  cometa_runtime_ref(runtime);
  cardano_error_t result = cardano_tx_evaluator_new(impl, output);
  if (result != CARDANO_SUCCESS)
  {
    cometa_runtime_release(runtime);
  }
  return (unsigned int)result;
}

static unsigned int
run_evaluator(unsigned int from_provider, cometa_runtime_t* runtime, const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, uint32_t count, cardano_buffer_t** output)
{
  if (output != NULL)
  {
    *output = NULL;
  }
  if (runtime == NULL || transaction == NULL || utxos == NULL || output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  if (count == 0)
  {
    return (unsigned int)CARDANO_ERROR_INVALID_ARGUMENT;
  }
  cardano_provider_t*      provider    = NULL;
  cardano_tx_evaluator_t*  evaluator   = NULL;
  cardano_transaction_t*   tx          = NULL;
  cardano_utxo_list_t*     additional  = NULL;
  cardano_redeemer_list_t* redeemers   = NULL;
  cardano_cbor_reader_t*   tx_reader   = cardano_cbor_reader_new(transaction, transaction_size);
  cardano_cbor_reader_t*   utxo_reader = cardano_cbor_reader_new(utxos, utxos_size);
  cardano_cbor_writer_t*   writer      = cardano_cbor_writer_new();
  cardano_error_t          result      = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  if (tx_reader == NULL || utxo_reader == NULL || writer == NULL)
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
    if (from_provider == 0)
    {
      result = (cardano_error_t)cometa_evaluation_new(runtime, &evaluator);
    }
    else
    {
      static const unsigned char name[] = "Cometa evaluator provider";
      result                            = (cardano_error_t)cometa_provider_runtime_new(runtime, name, sizeof(name) - 1, 0, &provider);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_tx_evaluator_from_provider(provider, &evaluator);
      }
      /* The evaluator retained its own provider owner on success. This local
       * construction obligation is released once regardless of pointer value. */
      cardano_provider_unref(&provider);
      provider = NULL;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    /* Exercise the native evaluator through a retained alias. Native unref leaves
     * its pointer nonnull while that alias keeps the object alive. */
    cardano_tx_evaluator_t* retained = evaluator;
    cardano_tx_evaluator_ref(retained);
    cardano_tx_evaluator_unref(&evaluator);
    evaluator = retained;
    for (uint32_t index = 0; result == CARDANO_SUCCESS && index < count; ++index)
    {
      cardano_redeemer_list_unref(&redeemers);
      redeemers = NULL;
      result    = cardano_tx_evaluator_evaluate(evaluator, tx, additional, &redeemers);
    }
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
    cardano_buffer_unref(output);
    *output = NULL;
  }
  cardano_redeemer_list_unref(&redeemers);
  cardano_tx_evaluator_unref(&evaluator);
  cardano_utxo_list_unref(&additional);
  cardano_transaction_unref(&tx);
  cardano_cbor_reader_unref(&utxo_reader);
  cardano_cbor_reader_unref(&tx_reader);
  cardano_cbor_writer_unref(&writer);
  return (unsigned int)result;
}

unsigned int
cometa_evaluation_run(cometa_runtime_t* runtime, const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, uint32_t count, cardano_buffer_t** output)
{
  return run_evaluator(0, runtime, transaction, transaction_size, utxos, utxos_size, count, output);
}

unsigned int
cometa_evaluation_run_provider(cometa_runtime_t* runtime, const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, uint32_t count, cardano_buffer_t** output)
{
  return run_evaluator(1, runtime, transaction, transaction_size, utxos, utxos_size, count, output);
}
