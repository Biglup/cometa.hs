#ifndef COMETA_PROVIDER_H
#define COMETA_PROVIDER_H

#include <cardano/providers/provider.h>
#include <HsFFI.h>
#include <stddef.h>
#include <stdint.h>

/* All inputs are borrowed until return. Write a native status, a 0/1 output,
 * and at most error_size bytes including the diagnostic terminator. The bridge
 * must contain every Haskell exception before returning through this ABI. */
typedef int (*cometa_confirmation_callback_t)(
  HsStablePtr          state,
  const unsigned char* hash,
  size_t               hash_size,
  uint64_t             timeout_ms,
  int*                 confirmed,
  char*                error,
  size_t               error_size);

/* Creates one owned provider reference. On success the native provider adopts
 * a context owning both runtime handles; its final destruction releases them.
 * On failure neither handle is transferred and the caller must release both. */
cardano_error_t cometa_provider_new(
  HsStablePtr                    state,
  cometa_confirmation_callback_t callback,
  cardano_provider_t**           provider);
/* Acquires another reference. The Haskell adapter serializes all refcount
 * transitions for aliases, because cardano-c reference counts are non-atomic. */
void cometa_provider_ref(cardano_provider_t* provider);
/* Unary adapter: consumes one reference even when another owner retains it.
 * Call only after this owner's native operations have joined. Final destruction
 * calls HsFFI handle-release functions; there are no user cleanup callbacks. */
void cometa_provider_release(cardano_provider_t* provider);
/* Borrows the provider and input bytes for the complete synchronous call.
 * The caller must retain an operation reference until return. Hash storage is
 * constructed and released here; bool layout never crosses the Haskell ABI. */
cardano_error_t cometa_provider_confirm(
  cardano_provider_t*  provider,
  const unsigned char* hash,
  size_t               hash_size,
  uint64_t             timeout_ms,
  int*                 confirmed);
/* Borrows the provider-owned error string; copy before releasing its owner or
 * starting another operation, which may overwrite it. */
const char* cometa_provider_error(const cardano_provider_t* provider);
/* Internal lifetime evidence. Counts use C11 atomics across independent providers. */
size_t cometa_callback_live_contexts(void);
size_t cometa_callback_completed_calls(void);

#endif
