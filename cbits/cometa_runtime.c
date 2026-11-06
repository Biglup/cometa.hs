/**
 * \file cometa_runtime.c
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
#include <stdatomic.h>
#include <stdlib.h>

/* TYPES *********************************************************************/
struct cometa_runtime_t
{
    cardano_object_t          base;
    HsStablePtr               state;
    cometa_runtime_callback_t callback;
};

/* STATIC FUNCTIONS **********************************************************/
static atomic_size_t live_contexts = 0U;

/** \brief Final native owner releases the Haskell registration without user callbacks. */
static void
destroy(void* object)
{
  cometa_runtime_t* context = (cometa_runtime_t*)object;
  hs_free_fun_ptr((HsFunPtr)context->callback);
  hs_free_stable_ptr(context->state);
  atomic_fetch_sub(&live_contexts, 1U);
  free(context);
}

/* DEFINITIONS ***************************************************************/
unsigned int
cometa_runtime_new(HsStablePtr state, cometa_runtime_callback_t callback, cometa_runtime_t** output)
{
  if (output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output = NULL;
  if ((state == NULL) || (callback == NULL))
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  cometa_runtime_t* context = calloc(1U, sizeof(cometa_runtime_t));
  if (context == NULL)
  {
    return (unsigned int)CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  context->base.ref_count   = 1U;
  context->base.deallocator = destroy;
  context->state            = state;
  context->callback         = callback;
  atomic_fetch_add(&live_contexts, 1U);
  *output = context;
  return (unsigned int)CARDANO_SUCCESS;
}

void
cometa_runtime_ref(cometa_runtime_t* context)
{
  if (context != NULL)
  {
    cardano_object_ref(&context->base);
  }
}

void
cometa_runtime_release(cometa_runtime_t* context)
{
  if (context != NULL)
  {
    cardano_object_t* object = &context->base;
    cardano_object_unref(&object);
  }
}

cardano_object_t*
cometa_runtime_object(cometa_runtime_t* context)
{
  return context == NULL ? NULL : &context->base;
}

unsigned int
cometa_runtime_dispatch(cometa_runtime_t* context, uint32_t operation, const unsigned char* request, size_t size, cardano_buffer_t** reply, char* error, size_t capacity)
{
  if (reply == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *reply = NULL;
  if ((context == NULL) || ((request == NULL) && (size != 0U)))
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  return context->callback(context->state, operation, request, size, reply, error, capacity);
}

unsigned int
cometa_runtime_buffer_new(const unsigned char* bytes, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output = cardano_buffer_new_from(bytes, size);
  return (unsigned int)(*output == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS);
}

void
cometa_runtime_buffer_release(cardano_buffer_t** buffer)
{
  cardano_buffer_unref(buffer);
}

const unsigned char*
cometa_runtime_buffer_data(const cardano_buffer_t* buffer)
{
  return cardano_buffer_get_data(buffer);
}

size_t
cometa_runtime_buffer_size(const cardano_buffer_t* buffer)
{
  return cardano_buffer_get_size(buffer);
}

size_t
cometa_runtime_live_contexts(void)
{
  return atomic_load(&live_contexts);
}
