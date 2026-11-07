/**
 * \file runtime_oracle.c
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
#include "cometa_runtime.h"
#include <cardano/cardano.h>
#include <cardano/providers/provider.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif
#include <string.h>

/* TYPES *********************************************************************/
typedef struct probe_request_t
{
    cometa_runtime_t* context;
    unsigned int      status;
} probe_request_t;

/* STATIC FUNCTIONS **********************************************************/
/** \brief Independent C callback thread owns and releases its complete reply. */
#ifdef _WIN32
static DWORD WINAPI
#else
static void*
#endif
invoke(void* input)
{
  probe_request_t*    request   = (probe_request_t*)input;
  const unsigned char bytes     = 0x80U;
  cardano_buffer_t*   reply     = NULL;
  char                error[64] = { 0 };
  request->status               = cometa_runtime_dispatch(request->context, 0U, &bytes, 1U, &reply, error, sizeof(error));
  cardano_buffer_unref(&reply);
  return 0;
}

/* DEFINITIONS ***************************************************************/
/** \brief Synchronous native retry/handled-failure and grouped-context probe.
 * Every reply obligation is released before replacement or failure; successful
 * output ownership transfers to the Haskell test operation.
 */
unsigned int
cometa_test_runtime_probe(cometa_runtime_t* first, cometa_runtime_t* second, unsigned int mode, cardano_buffer_t** output)
{
  *output = NULL;
  if (mode == 4U)
  {
    probe_request_t requests[2] = { { first, 0U }, { second, 0U } };
#ifdef _WIN32
    HANDLE threads[2];
    threads[0] = CreateThread(NULL, 0, invoke, &requests[0], 0, NULL);
    if (threads[0] == NULL)
    {
      return 1U;
    }
    threads[1] = CreateThread(NULL, 0, invoke, &requests[1], 0, NULL);
    if (threads[1] == NULL)
    {
      invoke(&requests[1]);
      WaitForSingleObject(threads[0], INFINITE);
      CloseHandle(threads[0]);
      return 1U;
    }
    WaitForMultipleObjects(2, threads, TRUE, INFINITE);
    CloseHandle(threads[0]);
    CloseHandle(threads[1]);
#else
    pthread_t threads[2];
    if (pthread_create(&threads[0], NULL, invoke, &requests[0]) != 0)
    {
      return 1U;
    }
    if (pthread_create(&threads[1], NULL, invoke, &requests[1]) != 0)
    {
      invoke(&requests[1]);
      pthread_join(threads[0], NULL);
      return 1U;
    }
    pthread_join(threads[0], NULL);
    pthread_join(threads[1], NULL);
#endif
    const unsigned char empty = 0x80U;
    if (requests[0].status == 0U && requests[1].status == 0U)
    {
      return cometa_runtime_buffer_new(&empty, 1U, output);
    }
    return 1U;
  }

  const unsigned char request   = 0x80U;
  char                error[64] = { 0 };
  unsigned int        result    = cometa_runtime_dispatch(first, 0U, &request, 1U, output, error, sizeof(error));
  if (mode == 1U)
  {
    cardano_buffer_unref(output);
    *output = NULL;

    return cometa_runtime_buffer_new(&request, 1U, output);
  }
  if (mode == 2U || mode == 3U)
  {
    cardano_buffer_unref(output);
    *output = NULL;
    result  = cometa_runtime_dispatch(mode == 3U ? second : first, 1U, &request, 1U, output, error, sizeof(error));
  }
  if (result != 0U)
  {
    cardano_buffer_unref(output);
    *output = NULL;
  }
  return result;
}

/** \brief Copy actual native provider metadata through a fixed scalar ABI. */
unsigned int
cometa_test_provider_metadata(cardano_provider_t* provider, unsigned char* name, size_t capacity, uint32_t* magic)
{
  const char* source = cardano_provider_get_name(provider);
  size_t      size   = strlen(source);
  if (size >= capacity)
  {
    return (unsigned int)CARDANO_ERROR_INVALID_ARGUMENT;
  }
  memcpy(name, source, size + 1U);
  *magic = (uint32_t)cardano_provider_get_network_magic(provider);
  return (unsigned int)CARDANO_SUCCESS;
}

/** Measure public encodings through independent native parsers and calculators.
 * Kind 3 prices only execution, using memory=7/3 and steps=11/7 lovelace.
 * Every parsed owner and construction reference is released before returning. */
int
cometa_test_building_sizes_oracle(uint8_t kind, const unsigned char* bytes, size_t size, uint64_t* output)
{
  cardano_error_t               result     = CARDANO_SUCCESS;
  cardano_cbor_reader_t*        reader     = cardano_cbor_reader_new(bytes, size);
  cardano_transaction_t*        tx         = NULL;
  cardano_transaction_output_t* tx_output  = NULL;
  cardano_script_t*             script     = NULL;
  cardano_unit_interval_t*      memory     = NULL;
  cardano_unit_interval_t*      steps      = NULL;
  cardano_unit_interval_t*      ref_price  = NULL;
  cardano_ex_unit_prices_t*     prices     = NULL;
  cardano_utxo_list_t*          references = NULL;
  size_t                        measured   = 0;
  if (reader == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  switch (kind)
  {
    case 0:
      result = cardano_transaction_from_cbor(reader, &tx);
      if (result == CARDANO_SUCCESS)
        result = cardano_get_serialized_transaction_size(tx, &measured);
      break;
    case 1:
      result = cardano_transaction_output_from_cbor(reader, &tx_output);
      if (result == CARDANO_SUCCESS)
        result = cardano_get_serialized_output_size(tx_output, &measured);
      break;
    case 2:
      result = cardano_script_from_cbor(reader, &script);
      if (result == CARDANO_SUCCESS)
        result = cardano_get_serialized_script_size(script, &measured);
      break;
    case 3:
      result = cardano_transaction_from_cbor(reader, &tx);
      if (result == CARDANO_SUCCESS)
        result = cardano_unit_interval_new(7, 3, &memory);
      if (result == CARDANO_SUCCESS)
        result = cardano_unit_interval_new(11, 7, &steps);
      if (result == CARDANO_SUCCESS)
        result = cardano_unit_interval_new(0, 1, &ref_price);
      if (result == CARDANO_SUCCESS)
        result = cardano_ex_unit_prices_new(memory, steps, &prices);
      if (result == CARDANO_SUCCESS)
        result = cardano_utxo_list_new(&references);
      if (result == CARDANO_SUCCESS)
        result = cardano_compute_min_script_fee(tx, prices, references, ref_price, output);
      break;
    default:
      result = CARDANO_ERROR_INVALID_ARGUMENT;
  }
  if ((result == CARDANO_SUCCESS) && (kind != 3))
    *output = measured;
  cardano_utxo_list_unref(&references);
  cardano_ex_unit_prices_unref(&prices);
  cardano_unit_interval_unref(&memory);
  cardano_unit_interval_unref(&steps);
  cardano_unit_interval_unref(&ref_price);
  cardano_script_unref(&script);
  cardano_transaction_output_unref(&tx_output);
  cardano_transaction_unref(&tx);
  cardano_cbor_reader_unref(&reader);
  return result;
}
