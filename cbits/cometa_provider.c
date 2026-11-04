#include "cometa_provider.h"

#include <cardano/crypto/blake2b_hash.h>
#include <cardano/object.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct cometa_provider_context_t
{
    cardano_object_t               base;
    HsStablePtr                    state;
    cometa_confirmation_callback_t callback;
} cometa_provider_context_t;

static atomic_size_t live_contexts   = 0U;
static atomic_size_t completed_calls = 0U;

static void
cometa_provider_context_deallocate(void* object)
{
  cometa_provider_context_t* context = (cometa_provider_context_t*)object;
  /* No callback is executing: each operation owns a provider reference. */
  hs_free_fun_ptr((HsFunPtr)context->callback);
  hs_free_stable_ptr(context->state);
  atomic_fetch_sub(&live_contexts, 1U);
  free(context);
}

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
  *confirmed                         = false;
  impl->error_message[0]             = '\0';
  cardano_error_t result             = (cardano_error_t)context->callback(
    context->state, cardano_blake2b_hash_get_data(hash), cardano_blake2b_hash_get_bytes_size(hash), timeout_ms, &value, impl->error_message, sizeof(impl->error_message));

  if (result == CARDANO_SUCCESS)
  {
    *confirmed = value != 0;
  }

  return result;
}

cardano_error_t
cometa_provider_new(
  HsStablePtr                    state,
  cometa_confirmation_callback_t callback,
  cardano_provider_t**           provider)
{
  if ((state == NULL) || (callback == NULL) || (provider == NULL))
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  *provider                          = NULL;
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
    /* Native construction did not adopt the context or runtime handles. */
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

cardano_error_t
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

  *confirmed                     = 0;
  bool                    value  = false;
  cardano_blake2b_hash_t* tx_id  = NULL;
  cardano_error_t         result = cardano_blake2b_hash_from_bytes(hash, hash_size, &tx_id);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_provider_confirm_transaction(provider, tx_id, timeout_ms, &value);
  }

  cardano_blake2b_hash_unref(&tx_id);
  *confirmed = value ? 1 : 0;
  /* Increment strictly after the native callback-capable operation unwinds. */
  atomic_fetch_add(&completed_calls, 1U);
  return result;
}

const char*
cometa_provider_error(const cardano_provider_t* provider)
{
  return cardano_provider_get_last_error(provider);
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
