/**
 * \file cometa_provider_runtime.c
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
#include "cometa_provider_runtime.h"
#include "cometa_parameters.h"
#include <cardano/cardano.h>
#include <stdlib.h>
#include <string.h>

/* TYPES *********************************************************************/
typedef struct provider_context_t
{
    cardano_object_t  base;
    cometa_runtime_t* runtime;
    cardano_buffer_t* parameter_template;
} provider_context_t;

/* STATIC FUNCTIONS **********************************************************/
/** \brief This provider owns its runtime reference and optional parameter availability sidecar. */
static void
destroy_provider_context(void* object)
{
  provider_context_t* context = (provider_context_t*)object;
  cardano_buffer_unref(&context->parameter_template);
  cometa_runtime_release(context->runtime);
  free(context);
}

/** \brief Reject trailing wire bytes before transferring any decoded output. */
static cardano_error_t
complete(cardano_cbor_reader_t* reader)
{
  size_t          remaining = 0U;
  cardano_error_t result    = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  return result == CARDANO_SUCCESS && remaining != 0U ? CARDANO_ERROR_DECODING : result;
}

/** \brief Copy a native address into a CBOR byte string. */
static cardano_error_t
write_address(cardano_cbor_writer_t* writer, cardano_address_t* address)
{
  size_t         size  = cardano_address_get_bytes_size(address);
  unsigned char* bytes = malloc(size == 0U ? 1U : size);
  if (bytes == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  cardano_error_t result = cardano_address_to_bytes(address, bytes, size);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_bytestring(writer, bytes, size);
  }
  free(bytes);
  return result;
}

/** \brief Decode a borrowed wire address; byte buffer remains scoped until construction copies it. */
static cardano_error_t
read_address(cardano_cbor_reader_t* reader, cardano_address_t** address)
{
  cardano_buffer_t* bytes  = NULL;
  cardano_error_t   result = cardano_cbor_reader_read_bytestring(reader, &bytes);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_address_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), address);
  }
  cardano_buffer_unref(&bytes);
  return result;
}

/** \brief Empty bytes identify Ada; native assets carry policy bytes followed by name bytes. */
static cardano_error_t
read_asset(cardano_cbor_reader_t* reader, cardano_asset_id_t** asset)
{
  cardano_buffer_t* bytes  = NULL;
  cardano_error_t   result = cardano_cbor_reader_read_bytestring(reader, &bytes);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_buffer_get_size(bytes) == 0U ? cardano_asset_id_new_lovelace(asset)
                                                  : cardano_asset_id_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), asset);
  }
  cardano_buffer_unref(&bytes);
  return result;
}

/** \brief Decode one owned digest from a wire byte string. */
static cardano_error_t
read_hash(cardano_cbor_reader_t* reader, cardano_blake2b_hash_t** hash)
{
  cardano_buffer_t* bytes  = NULL;
  cardano_error_t   result = cardano_cbor_reader_read_bytestring(reader, &bytes);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_blake2b_hash_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), hash);
  }
  cardano_buffer_unref(&bytes);
  return result;
}

/** \brief Serialize every resolved output through its native typed codec. */
static cardano_error_t
write_utxos(cardano_cbor_writer_t* writer, cardano_utxo_list_t* list)
{
  size_t          count  = cardano_utxo_list_get_length(list);
  cardano_error_t result = cardano_cbor_writer_write_start_array(writer, (int64_t)count);
  for (size_t index = 0U; result == CARDANO_SUCCESS && index < count; ++index)
  {
    cardano_utxo_t* value = NULL;
    result                = cardano_utxo_list_get(list, index, &value);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_to_cbor(value, writer);
    }
    cardano_utxo_unref(&value);
  }
  return result;
}

/** \brief Construct an owned resolved-output list, releasing all partial elements on failure. */
static cardano_error_t
read_utxos(cardano_cbor_reader_t* reader, cardano_utxo_list_t** list)
{
  *list                  = NULL;
  int64_t         count  = 0;
  cardano_error_t result = cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_utxo_list_new(list);
  }
  cardano_cbor_reader_state_t state = CARDANO_CBOR_READER_STATE_UNDEFINED;
  while (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_peek_state(reader, &state);
    if (result != CARDANO_SUCCESS || state == CARDANO_CBOR_READER_STATE_END_ARRAY)
    {
      break;
    }
    cardano_utxo_t* value = NULL;
    result                = cardano_utxo_from_cbor(reader, &value);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_list_add(*list, value);
    }
    cardano_utxo_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_utxo_list_unref(list);
    *list = NULL;
  }
  return result;
}

/** \brief Encode a request then borrow the returned buffer through its reader lifetime. */
static cardano_error_t
dispatch(cardano_provider_impl_t* impl, uint32_t operation, cardano_cbor_writer_t* writer, cardano_cbor_reader_t** reader, cardano_buffer_t** reply)
{
  *reader                   = NULL;
  *reply                    = NULL;
  cardano_buffer_t* request = NULL;
  cardano_error_t   result  = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_encode_in_buffer(writer, &request);
  if (result == CARDANO_SUCCESS)
  {
    provider_context_t* context = (provider_context_t*)impl->context;
    result                      = (cardano_error_t)cometa_runtime_dispatch(context->runtime, operation, cardano_buffer_get_data(request), cardano_buffer_get_size(request), reply, impl->error_message, sizeof(impl->error_message));
  }
  if (result == CARDANO_SUCCESS)
  {
    *reader = cardano_cbor_reader_new(cardano_buffer_get_data(*reply), cardano_buffer_get_size(*reply));
    if (*reader == NULL)
    {
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    }
  }
  cardano_buffer_unref(&request);
  return result;
}

/** \brief Typed native parameters callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_parameters(cardano_provider_impl_t* impl, cardano_protocol_parameters_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_start_array(writer, 0);
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 0U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cometa_parameters_from_snapshot(cardano_buffer_get_data(reply), cardano_buffer_get_size(reply), output);
    if (result == CARDANO_SUCCESS)
    {
      provider_context_t* context = (provider_context_t*)impl->context;
      cardano_buffer_unref(&context->parameter_template);
      context->parameter_template = reply;
      cardano_buffer_ref(reply);
    }
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_protocol_parameters_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native utxos callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_utxos(cardano_provider_impl_t* impl, cardano_address_t* address, cardano_utxo_list_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : write_address(writer, address);
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 1U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_utxo_list_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native rewards callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_rewards(cardano_provider_impl_t* impl, cardano_reward_address_t* address, uint64_t* output)
{
  *output                        = 0U;
  cardano_address_t*     generic = cardano_reward_address_to_address(address);
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader  = NULL;
  cardano_buffer_t*      reply   = NULL;
  cardano_error_t        result  = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : write_address(writer, generic);
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 2U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_uint(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    *output = 0U;
  }
  cardano_address_unref(&generic);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native asset_utxos callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_asset_utxos(cardano_provider_impl_t* impl, cardano_address_t* address, cardano_asset_id_t* asset, cardano_utxo_list_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_start_array(writer, 2);
  if (result == CARDANO_SUCCESS)
  {
    result = write_address(writer, address);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_bytestring(writer, cardano_asset_id_get_bytes(asset), cardano_asset_id_get_bytes_size(asset));
  }
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 3U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_utxo_list_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native nft callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_nft(cardano_provider_impl_t* impl, cardano_asset_id_t* asset, cardano_utxo_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_bytestring(writer, cardano_asset_id_get_bytes(asset), cardano_asset_id_get_bytes_size(asset));
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 4U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_cbor_reader_state_t state = CARDANO_CBOR_READER_STATE_UNDEFINED;
    result                            = cardano_cbor_reader_peek_state(reader, &state);
    if (result == CARDANO_SUCCESS && state == CARDANO_CBOR_READER_STATE_NULL)
    {
      result = CARDANO_ERROR_ELEMENT_NOT_FOUND;
    }
    else if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_from_cbor(reader, output);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_utxo_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native resolve callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_resolve(cardano_provider_impl_t* impl, cardano_transaction_input_set_t* inputs, cardano_utxo_list_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_transaction_input_set_to_cbor(inputs, writer);
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 5U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_utxos(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_utxo_list_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native datum callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_datum(cardano_provider_impl_t* impl, cardano_blake2b_hash_t* hash, cardano_plutus_data_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_bytestring(writer, cardano_blake2b_hash_get_data(hash), cardano_blake2b_hash_get_bytes_size(hash));
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 6U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_cbor_reader_state_t state = CARDANO_CBOR_READER_STATE_UNDEFINED;
    result                            = cardano_cbor_reader_peek_state(reader, &state);
    if (result == CARDANO_SUCCESS && state == CARDANO_CBOR_READER_STATE_NULL)
    {
      result = CARDANO_ERROR_ELEMENT_NOT_FOUND;
    }
    else if (result == CARDANO_SUCCESS)
    {
      result = cardano_plutus_data_from_cbor(reader, output);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_plutus_data_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native confirm callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_confirm(cardano_provider_impl_t* impl, cardano_blake2b_hash_t* hash, uint64_t timeout, bool* output)
{
  *output = false;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_start_array(writer, 2);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_bytestring(writer, cardano_blake2b_hash_get_data(hash), cardano_blake2b_hash_get_bytes_size(hash));
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_uint(writer, timeout);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 7U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_bool(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    *output = false;
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native submit callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_submit(cardano_provider_impl_t* impl, cardano_transaction_t* transaction, cardano_blake2b_hash_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_transaction_to_cbor(transaction, writer);
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 8U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = read_hash(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_blake2b_hash_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/** \brief Typed native evaluate callback; temporaries remain operation-owned through decode/transfer. */
static cardano_error_t
callback_evaluate(cardano_provider_impl_t* impl, cardano_transaction_t* transaction, cardano_utxo_list_t* utxos, cardano_redeemer_list_t** output)
{
  *output = NULL;

  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader = NULL;
  cardano_buffer_t*      reply  = NULL;
  cardano_error_t        result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_writer_write_start_array(writer, 2);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_to_cbor(transaction, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = write_utxos(writer, utxos);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = dispatch(impl, 9U, writer, &reader, &reply);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_redeemer_list_from_cbor(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_redeemer_list_unref(output);
  }

  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&reply);
  return result;
}

/* DEFINITIONS ***************************************************************/
static unsigned int
new_provider(cometa_runtime_t* runtime, const unsigned char* name, size_t name_size, uint32_t magic, cardano_provider_t** output, provider_context_t** context_output)
{
  if (output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output = NULL;
  if (runtime == NULL || name == NULL || name_size > 255U || memchr(name, 0, name_size) != NULL)
  {
    return (unsigned int)CARDANO_ERROR_INVALID_ARGUMENT;
  }
  provider_context_t* context = calloc(1U, sizeof(provider_context_t));
  if (context == NULL)
  {
    return (unsigned int)CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  context->base.ref_count   = 1U;
  context->base.deallocator = destroy_provider_context;
  context->runtime          = runtime;
  cometa_runtime_ref(runtime);
  cardano_provider_impl_t impl = { 0 };
  memcpy(impl.name, name, name_size);
  impl.network_magic                  = magic;
  impl.context                        = &context->base;
  impl.get_parameters                 = callback_parameters;
  impl.get_unspent_outputs            = callback_utxos;
  impl.get_rewards_balance            = callback_rewards;
  impl.get_unspent_outputs_with_asset = callback_asset_utxos;
  impl.get_unspent_output_by_nft      = callback_nft;
  impl.resolve_unspent_outputs        = callback_resolve;
  impl.resolve_datum                  = callback_datum;
  impl.await_transaction_confirmation = callback_confirm;
  impl.post_transaction_to_chain      = callback_submit;
  impl.evaluate_transaction           = callback_evaluate;
  cardano_error_t result              = cardano_provider_new(impl, output);
  if (result == CARDANO_SUCCESS && context_output != NULL)
  {
    *context_output = context;
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_object_t* object = &context->base;
    cardano_object_unref(&object);
  }
  return (unsigned int)result;
}

unsigned int
cometa_provider_runtime_new(cometa_runtime_t* runtime, const unsigned char* name, size_t name_size, uint32_t magic, cardano_provider_t** output)
{
  return new_provider(runtime, name, name_size, magic, output, NULL);
}

unsigned int
cometa_provider_runtime_call(cometa_runtime_t* runtime, const unsigned char* name, size_t name_size, uint32_t magic, uint32_t operation, const unsigned char* input, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output                                           = NULL;
  cardano_provider_t*              provider         = NULL;
  provider_context_t*              provider_context = NULL;
  cardano_cbor_reader_t*           reader           = NULL;
  cardano_cbor_writer_t*           writer           = NULL;
  cardano_error_t                  result           = (cardano_error_t)new_provider(runtime, name, name_size, magic, &provider, &provider_context);
  cardano_protocol_parameters_t*   parameters       = NULL;
  cardano_address_t*               address          = NULL;
  cardano_reward_address_t*        reward           = NULL;
  cardano_asset_id_t*              asset            = NULL;
  cardano_utxo_list_t*             utxos            = NULL;
  cardano_utxo_list_t*             additional       = NULL;
  cardano_utxo_t*                  utxo             = NULL;
  cardano_transaction_input_set_t* inputs           = NULL;
  cardano_blake2b_hash_t*          hash             = NULL;
  cardano_plutus_data_t*           datum            = NULL;
  cardano_transaction_t*           transaction      = NULL;
  cardano_redeemer_list_t*         redeemers        = NULL;
  uint64_t                         scalar           = 0U;
  bool                             confirmed        = false;
  int64_t                          arity            = 0;
  if (result == CARDANO_SUCCESS)
  {
    reader = cardano_cbor_reader_new(input, size);
    writer = cardano_cbor_writer_new();
    if (reader == NULL || writer == NULL)
    {
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    switch (operation)
    {
      case 0U:
        result = cardano_cbor_reader_read_start_array(reader, &arity);
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_cbor_reader_read_end_array(reader);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_get_parameters(provider, &parameters);
          }
        }
        if (result == CARDANO_SUCCESS)
        {
          /* The callback's exact snapshot supplies only availability; actual values are read from native parameters. */
          result = cometa_parameters_to_snapshot(parameters, cardano_buffer_get_data(provider_context->parameter_template), cardano_buffer_get_size(provider_context->parameter_template), output);
        }
        break;
      case 1U:
      case 2U:
      case 3U:
        if (operation == 3U)
        {
          result = cardano_cbor_reader_read_start_array(reader, &arity);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = read_address(reader, &address);
        }
        if (result == CARDANO_SUCCESS && operation == 1U)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_get_unspent_outputs(provider, address, &utxos);
          }
        }
        if (result == CARDANO_SUCCESS && operation == 2U)
        {
          result = cardano_reward_address_from_address(address, &reward);
        }
        if (result == CARDANO_SUCCESS && operation == 2U)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_get_rewards_available(provider, reward, &scalar);
          }
        }
        if (result == CARDANO_SUCCESS && operation == 3U)
        {
          result = read_asset(reader, &asset);
        }
        if (result == CARDANO_SUCCESS && operation == 3U)
        {
          result = cardano_cbor_reader_read_end_array(reader);
        }
        if (result == CARDANO_SUCCESS && operation == 3U)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_get_unspent_outputs_with_asset(provider, address, asset, &utxos);
          }
        }
        if (result == CARDANO_SUCCESS)
        {
          result = operation == 2U ? cardano_cbor_writer_write_uint(writer, scalar) : write_utxos(writer, utxos);
        }
        break;
      case 4U:
        result = read_asset(reader, &asset);
        if (result == CARDANO_SUCCESS)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_get_unspent_output_by_nft(provider, asset, &utxo);
          }
        }
        if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
        {
          result = cardano_cbor_writer_write_null(writer);
        }
        else if (result == CARDANO_SUCCESS)
        {
          result = cardano_utxo_to_cbor(utxo, writer);
        }
        break;
      case 5U:
        result = cardano_transaction_input_set_from_cbor(reader, &inputs);
        if (result == CARDANO_SUCCESS)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_resolve_unspent_outputs(provider, inputs, &utxos);
          }
        }
        if (result == CARDANO_SUCCESS)
        {
          result = write_utxos(writer, utxos);
        }
        break;
      case 6U:
        result = read_hash(reader, &hash);
        if (result == CARDANO_SUCCESS)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_resolve_datum(provider, hash, &datum);
          }
        }
        if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
        {
          result = cardano_cbor_writer_write_null(writer);
        }
        else if (result == CARDANO_SUCCESS)
        {
          result = cardano_plutus_data_to_cbor(datum, writer);
        }
        break;
      case 7U:
        result = cardano_cbor_reader_read_start_array(reader, &arity);
        if (result == CARDANO_SUCCESS)
        {
          result = read_hash(reader, &hash);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_cbor_reader_read_uint(reader, &scalar);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_cbor_reader_read_end_array(reader);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_confirm_transaction(provider, hash, scalar, &confirmed);
          }
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_cbor_writer_write_bool(writer, confirmed);
        }
        break;
      case 8U:
        result = cardano_transaction_from_cbor(reader, &transaction);
        if (result == CARDANO_SUCCESS)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_submit_transaction(provider, transaction, &hash);
          }
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_cbor_writer_write_bytestring(writer, cardano_blake2b_hash_get_data(hash), cardano_blake2b_hash_get_bytes_size(hash));
        }
        break;
      case 9U:
        result = cardano_cbor_reader_read_start_array(reader, &arity);
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_transaction_from_cbor(reader, &transaction);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = read_utxos(reader, &additional);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_cbor_reader_read_end_array(reader);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = complete(reader);
          if (result == CARDANO_SUCCESS)
          {
            result = cardano_provider_evaluate_transaction(provider, transaction, additional, &redeemers);
          }
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_redeemer_list_to_cbor(redeemers, writer);
        }
        break;
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
  if (result == CARDANO_SUCCESS && operation != 0U)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
  cardano_protocol_parameters_unref(&parameters);
  cardano_address_unref(&address);
  cardano_reward_address_unref(&reward);
  cardano_asset_id_unref(&asset);
  cardano_utxo_list_unref(&utxos);
  cardano_utxo_list_unref(&additional);
  cardano_utxo_unref(&utxo);
  cardano_transaction_input_set_unref(&inputs);
  cardano_blake2b_hash_unref(&hash);
  cardano_plutus_data_unref(&datum);
  cardano_transaction_unref(&transaction);
  cardano_redeemer_list_unref(&redeemers);
  cardano_provider_unref(&provider);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  if (result != CARDANO_SUCCESS)
  {
    cardano_buffer_unref(output);
    *output = NULL;
  }
  return (unsigned int)result;
}
