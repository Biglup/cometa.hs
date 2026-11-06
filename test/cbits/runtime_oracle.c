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
