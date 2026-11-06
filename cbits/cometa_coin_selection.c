/**
 * \file cometa_coin_selection.c
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

#include "cometa_coin_selection.h"
#include "cometa_parameters.h"
#include <cardano/transaction_builder/coin_selection/coin_selector_impl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* STRUCTURES ****************************************************************/

/** \brief Adopted selector context; caller serializes refcount transitions. */
typedef struct selector_context_t
{
    cardano_object_t  base;
    cometa_runtime_t* runtime;
    cardano_buffer_t* parameter_template;
} selector_context_t;

/** \brief Own every field referenced by a borrowed native request structure. */
typedef struct owned_request_t
{
    cardano_coin_selection_request_t value;
    cardano_buffer_t*                parameter_template;
} owned_request_t;

/* STATIC FUNCTIONS **********************************************************/

/** \brief Release context roots only after native selector final destruction. */
static void
selector_context_free(void* opaque)
{
  selector_context_t* context = opaque;
  cardano_buffer_unref(&context->parameter_template);
  cometa_runtime_release(context->runtime);
  free(context);
}

/** \brief Consume exactly the local request-field ownership obligations. */
static void
request_free(owned_request_t* request)
{
  cardano_utxo_list_unref(&request->value.pre_selected_utxo);
  cardano_utxo_list_unref(&request->value.available_utxo);
  cardano_value_unref(&request->value.target);
  cardano_transaction_output_list_unref(&request->value.outputs_to_cover);
  cardano_address_unref(&request->value.change_address);
  cardano_protocol_parameters_unref(&request->value.protocol_params);
  cardano_buffer_unref(&request->parameter_template);
}

/** \brief Check complete consumption without borrowing reader storage past return. */
static cardano_error_t
reader_finished(cardano_cbor_reader_t* reader)
{
  size_t          remaining = 0U;
  cardano_error_t result    = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  return (result == CARDANO_SUCCESS && remaining != 0U) ? CARDANO_ERROR_INVALID_ARGUMENT : result;
}

/** \brief Decode an owned native UTxO list; each add retains before local release. */
static cardano_error_t
read_utxos(cardano_cbor_reader_t* reader, cardano_utxo_list_t** output)
{
  *output                = NULL;
  int64_t         count  = 0;
  cardano_error_t result = cardano_cbor_reader_read_start_array(reader, &count);
  if (result != CARDANO_SUCCESS || count < 0)
  {
    return result == CARDANO_SUCCESS ? CARDANO_ERROR_INVALID_ARGUMENT : result;
  }
  result = cardano_utxo_list_new(output);
  for (int64_t i = 0; result == CARDANO_SUCCESS && i < count; ++i)
  {
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

/** \brief Snapshot a borrowed list using retained element getters. */
static cardano_error_t
write_utxos(cardano_cbor_writer_t* writer, cardano_utxo_list_t* list)
{
  const size_t    count  = list == NULL ? 0U : cardano_utxo_list_get_length(list);
  cardano_error_t result = cardano_cbor_writer_write_start_array(writer, (int64_t)count);
  for (size_t i = 0U; result == CARDANO_SUCCESS && i < count; ++i)
  {
    cardano_utxo_t* item = NULL;
    result               = cardano_utxo_list_get(list, i, &item);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_to_cbor(item, writer);
    }
    cardano_utxo_unref(&item);
  }
  return result;
}

/** \brief Materialize all six request fields from an internal exact snapshot. */
static cardano_error_t
read_request(const unsigned char* bytes, size_t size, owned_request_t* output)
{
  memset(output, 0, sizeof(*output));
  cardano_cbor_reader_t* reader  = cardano_cbor_reader_new(bytes, size);
  cardano_buffer_t*      address = NULL;
  int64_t                count   = 0;
  cardano_error_t        result  = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS && count != 6)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(reader, &output->value.pre_selected_utxo);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(reader, &output->value.available_utxo);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_from_cbor(reader, &output->value.target);
  }
  cardano_cbor_reader_state_t state = CARDANO_CBOR_READER_STATE_UNDEFINED;
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_peek_state(reader, &state);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = state == CARDANO_CBOR_READER_STATE_NULL ? cardano_cbor_reader_read_null(reader) : cardano_transaction_output_list_from_cbor(reader, &output->value.outputs_to_cover);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_bytestring(reader, &address);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_address_from_bytes(cardano_buffer_get_data(address), cardano_buffer_get_size(address), &output->value.change_address);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_encoded_value(reader, &output->parameter_template);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_parameters_from_snapshot(cardano_buffer_get_data(output->parameter_template), cardano_buffer_get_size(output->parameter_template), &output->value.protocol_params);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = reader_finished(reader);
  }
  cardano_buffer_unref(&address);
  cardano_cbor_reader_unref(&reader);
  return result;
}

/** \brief Snapshot actual borrowed native request values before Haskell dispatch.
 * Parameter availability uses optional known-origin template, never echoed values.
 */
static cardano_error_t
write_request(selector_context_t* context, const cardano_coin_selection_request_t* request, cardano_buffer_t** output)
{
  *output                           = NULL;
  cardano_cbor_writer_t* writer     = cardano_cbor_writer_new();
  cardano_buffer_t*      parameters = NULL;
  cardano_error_t        result     = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_start_array(writer, 6);
  if (result == CARDANO_SUCCESS)
  {
    result = write_utxos(writer, request->pre_selected_utxo);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = write_utxos(writer, request->available_utxo);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_to_cbor(request->target, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = request->outputs_to_cover == NULL ? cardano_cbor_writer_write_null(writer) : cardano_transaction_output_list_to_cbor(request->outputs_to_cover, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_bytestring(writer, cardano_address_get_bytes(request->change_address), cardano_address_get_bytes_size(request->change_address));
  }
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_parameters_to_snapshot(request->protocol_params, context->parameter_template == NULL ? NULL : cardano_buffer_get_data(context->parameter_template), context->parameter_template == NULL ? 0U : cardano_buffer_get_size(context->parameter_template), &parameters);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_encoded(writer, cardano_buffer_get_data(parameters), cardano_buffer_get_size(parameters));
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
  cardano_buffer_unref(&parameters);
  cardano_cbor_writer_unref(&writer);
  return result;
}

/** \brief Decode all three callback outputs with independent failure cleanup. */
static cardano_error_t
read_selection(cardano_buffer_t* buffer, cardano_utxo_list_t** selected, cardano_utxo_list_t** remaining, cardano_transaction_output_list_t** change)
{
  cardano_cbor_reader_t* reader = cardano_cbor_reader_new(cardano_buffer_get_data(buffer), cardano_buffer_get_size(buffer));
  int64_t                count  = 0;
  cardano_error_t        result = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS && count != 3)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(reader, selected);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(reader, remaining);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_output_list_from_cbor(reader, change);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = reader_finished(reader);
  }
  cardano_cbor_reader_unref(&reader);
  return result;
}

/** \brief Native selector callback; output slots initialized and partial owners
 * released before any failure returns through the C ABI. Runtime contains and
 * later rethrows Haskell exceptions only after native unwind and ownership cleanup.
 */
static cardano_error_t
select_callback(cardano_coin_selector_impl_t* selector, const cardano_coin_selection_request_t* request, cardano_utxo_list_t** selected, cardano_utxo_list_t** remaining, cardano_transaction_output_list_t** change)
{
  *selected                          = NULL;
  *remaining                         = NULL;
  *change                            = NULL;
  selector_context_t* context        = (selector_context_t*)selector->context;
  cardano_buffer_t*   request_bytes  = NULL;
  cardano_buffer_t*   response_bytes = NULL;
  cardano_error_t     result         = write_request(context, request, &request_bytes);
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_runtime_dispatch(context->runtime, 200U, cardano_buffer_get_data(request_bytes), cardano_buffer_get_size(request_bytes), &response_bytes, selector->error_message, sizeof(selector->error_message));
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_selection(response_bytes, selected, remaining, change);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_utxo_list_unref(selected);
    *selected = NULL;
    cardano_utxo_list_unref(remaining);
    *remaining = NULL;
    cardano_transaction_output_list_unref(change);
    *change = NULL;
  }
  cardano_buffer_unref(&response_bytes);
  cardano_buffer_unref(&request_bytes);
  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_coin_selector_new(cometa_runtime_t* runtime, const unsigned char* parameter_template, size_t template_size, cardano_coin_selector_t** output)
{
  *output                     = NULL;
  selector_context_t* context = calloc(1U, sizeof(*context));
  if (context == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  context->base.ref_count   = 1U;
  context->base.deallocator = selector_context_free;
  context->runtime          = runtime;
  cometa_runtime_ref(runtime);
  cardano_error_t result = CARDANO_SUCCESS;
  if (parameter_template != NULL)
  {
    context->parameter_template = cardano_buffer_new_from(parameter_template, template_size);
    result                      = context->parameter_template == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_coin_selector_impl_t implementation = { 0 };
    (void)snprintf(implementation.name, sizeof(implementation.name), "%s", "Cometa selector");
    implementation.context = &context->base;
    implementation.select  = select_callback;
    result                 = cardano_coin_selector_new(implementation, output);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_object_t* owner = &context->base;
    cardano_object_unref(&owner);
  }
  return (unsigned int)result;
}

unsigned int
cometa_coin_selection_invoke(cometa_runtime_t* runtime, const unsigned char* bytes, size_t size, cardano_buffer_t** output)
{
  *output                                      = NULL;
  owned_request_t                    request   = { 0 };
  cardano_coin_selector_t*           selector  = NULL;
  cardano_utxo_list_t*               selected  = NULL;
  cardano_utxo_list_t*               remaining = NULL;
  cardano_transaction_output_list_t* change    = NULL;
  cardano_cbor_writer_t*             writer    = NULL;
  cardano_error_t                    result    = read_request(bytes, size, &request);
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_coin_selector_new(runtime, cardano_buffer_get_data(request.parameter_template), cardano_buffer_get_size(request.parameter_template), &selector);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_coin_selector_select(selector, &request.value, &selected, &remaining, &change);
  }
  if (result == CARDANO_SUCCESS)
  {
    writer = cardano_cbor_writer_new();
    result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_start_array(writer, 3);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = write_utxos(writer, selected);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = write_utxos(writer, remaining);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_output_list_to_cbor(change, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
  cardano_cbor_writer_unref(&writer);
  cardano_transaction_output_list_unref(&change);
  cardano_utxo_list_unref(&remaining);
  cardano_utxo_list_unref(&selected);
  cardano_coin_selector_unref(&selector);
  request_free(&request);
  return (unsigned int)result;
}

unsigned int
cometa_coin_selection_minimum_ada(const unsigned char* bytes, size_t size, uint64_t coins_per_byte, uint64_t* minimum)
{
  *minimum = 0U;
  if ((size > SIZE_MAX - 168U) || (coins_per_byte > UINT64_MAX / (size + 168U)))
  {
    return CARDANO_ERROR_INTEGER_OVERFLOW;
  }
  cardano_cbor_reader_t*        reader = cardano_cbor_reader_new(bytes, size);
  cardano_transaction_output_t* output = NULL;
  cardano_error_t               result = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_transaction_output_from_cbor(reader, &output);
  if (result == CARDANO_SUCCESS)
  {
    result = reader_finished(reader);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_compute_min_ada_required(output, coins_per_byte, minimum);
  }
  cardano_transaction_output_unref(&output);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
