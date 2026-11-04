/**
 * \file cometa_provider.c
 *
 * \author angel.castillo
 * \date   Nov 04, 2026
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

#include "cometa_provider.h"

#include <cardano/crypto/blake2b_hash.h>
#include <cardano/object.h>

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* STRUCTURES ****************************************************************/

/**
 * \brief Reference-counted context adopted by a native provider.
 *
 * The provider owns this context after successful construction. Its final destructor releases both
 * Haskell runtime handles only after every operation reference and retained provider alias is released.
 */
typedef struct cometa_provider_context_t
{
    /**
     * \brief Native reference-count header. Must be the first member for cardano_object_t compatibility.
     */
    cardano_object_t base;

    /**
     * \brief Owned stable pointer rooting the Haskell handler and active operation state.
     */
    HsStablePtr state;

    /**
     * \brief Owned Haskell callback trampoline, released only after the last possible invocation.
     */
    cometa_confirmation_callback_t callback;
} cometa_provider_context_t;

/* STATIC VARIABLES **********************************************************/

/**
 * \brief Number of adopted callback contexts whose final destruction has not completed.
 */
static atomic_size_t live_contexts = 0U;

/**
 * \brief Number of native confirmation calls that have returned and released temporary hashes.
 */
static atomic_size_t completed_calls = 0U;

/* STATIC FUNCTIONS **********************************************************/

/**
 * \brief Releases a provider context and its owned Haskell runtime handles.
 *
 * \param[in] object Context whose native reference count has reached zero. Must not be NULL.
 *
 * \note No callback is executing: each operation retains a provider reference until native unwind.
 *       The matching HsFFI release functions dispose of the trampoline and stable root before the
 *       context is freed with the same allocator family used at construction.
 */
static void
cometa_provider_context_deallocate(void* object)
{
  cometa_provider_context_t* context = (cometa_provider_context_t*)object;

  hs_free_fun_ptr((HsFunPtr)context->callback);
  hs_free_stable_ptr(context->state);

  atomic_fetch_sub(&live_contexts, 1U);

  free(context);
}

/**
 * \brief Adapts the native confirmation callback to the Haskell registration ABI.
 *
 * \param[in,out] impl       Provider implementation containing the adopted callback context and error buffer.
 * \param[in]     hash       Borrowed transaction identifier. Must remain valid throughout the callback.
 * \param[in]     timeout_ms Confirmation timeout in milliseconds.
 * \param[out]    confirmed  Pointer receiving the native confirmation result.
 *
 * \returns CARDANO_ERROR_POINTER_IS_NULL for a NULL argument, or the Haskell callback's native status.
 *
 * \note The Haskell bridge copies borrowed hash bytes, contains all exceptions, and waits for its user
 *       worker before returning. A successful integer output is converted to native bool here.
 */
static cardano_error_t
cometa_provider_await(
  cardano_provider_impl_t* impl,
  cardano_blake2b_hash_t*  hash,
  uint64_t                 timeout_ms,
  bool*                    confirmed)
{
  if ((impl == NULL) || (hash == NULL) || (confirmed == NULL))
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  cometa_provider_context_t* context = (cometa_provider_context_t*)impl->context;
  int                        value   = 0;

  *confirmed             = false;
  impl->error_message[0] = '\0';

  cardano_error_t result = (cardano_error_t)context->callback(
    context->state, cardano_blake2b_hash_get_data(hash), cardano_blake2b_hash_get_bytes_size(hash), timeout_ms, &value, impl->error_message, sizeof(impl->error_message));

  if (result == CARDANO_SUCCESS)
  {
    *confirmed = value != 0;
  }

  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_provider_new(
  HsStablePtr                    state,
  cometa_confirmation_callback_t callback,
  cardano_provider_t**           provider)
{
  if ((state == NULL) || (callback == NULL) || (provider == NULL))
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  *provider = NULL;

  cometa_provider_context_t* context = calloc(1U, sizeof(cometa_provider_context_t));

  if (context == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  context->base.ref_count   = 1U;
  context->base.deallocator = cometa_provider_context_deallocate;
  context->state            = state;
  context->callback         = callback;

  cardano_provider_impl_t impl = { 0 };

  memcpy(impl.name, "Cometa internal confirmation adapter", sizeof("Cometa internal confirmation adapter"));

  impl.context                        = &context->base;
  impl.await_transaction_confirmation = cometa_provider_await;

  cardano_error_t result = cardano_provider_new(impl, provider);

  if (result != CARDANO_SUCCESS)
  {
    // Native construction did not adopt the context or runtime handles.
    free(context);

    return result;
  }

  atomic_fetch_add(&live_contexts, 1U);

  return CARDANO_SUCCESS;
}

void
cometa_provider_ref(cardano_provider_t* provider)
{
  cardano_provider_ref(provider);
}

void
cometa_provider_release(cardano_provider_t* provider)
{
  cardano_provider_unref(&provider);
}

unsigned int
cometa_provider_confirm(
  cardano_provider_t*  provider,
  const unsigned char* hash,
  size_t               hash_size,
  uint64_t             timeout_ms,
  int*                 confirmed)
{
  if ((provider == NULL) || (hash == NULL) || (confirmed == NULL))
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  *confirmed = 0;

  bool                    value  = false;
  cardano_blake2b_hash_t* tx_id  = NULL;
  cardano_error_t         result = cardano_blake2b_hash_from_bytes(hash, hash_size, &tx_id);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_provider_confirm_transaction(provider, tx_id, timeout_ms, &value);
  }

  cardano_blake2b_hash_unref(&tx_id);

  *confirmed = value ? 1 : 0;

  // Increment strictly after the native callback-capable operation unwinds.
  atomic_fetch_add(&completed_calls, 1U);

  return result;
}

const char*
cometa_provider_error(const cardano_provider_t* provider)
{
  return cardano_provider_get_last_error(provider);
}

const char*
cometa_error_message(unsigned int code)
{
  return cardano_error_to_string((cardano_error_t)code);
}

size_t
cometa_callback_live_contexts(void)
{
  return atomic_load(&live_contexts);
}

size_t
cometa_callback_completed_calls(void)
{
  return atomic_load(&completed_calls);
}
