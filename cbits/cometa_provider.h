/**
 * \file cometa_provider.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_PROVIDER_H
#define BIGLUP_LABS_INCLUDE_COMETA_PROVIDER_H

/* INCLUDES ******************************************************************/

#include <cardano/providers/provider.h>

#include <HsFFI.h>
#include <stddef.h>
#include <stdint.h>

/* DECLARATIONS **************************************************************/

#ifdef __cplusplus
extern "C" {
#endif /* __cplusplus */

/* CALLBACKS *****************************************************************/

/**
 * \brief Function pointer type for invoking a Haskell transaction confirmation handler.
 *
 * All inputs and output buffers are borrowed until the callback returns. The Haskell bridge
 * copies the hash, runs the handler in a scoped worker, and forces its result before returning.
 * No Haskell exception may cross this callback ABI.
 *
 * \param[in]  state       Stable pointer to the Haskell callback state. Must not be NULL.
 * \param[in]  hash        Transaction identifier bytes. Must not be NULL.
 * \param[in]  hash_size   Number of bytes available at \p hash.
 * \param[in]  timeout_ms  Confirmation timeout in milliseconds.
 * \param[out] confirmed   Pointer receiving 0 or 1. Must not be NULL.
 * \param[out] error       Buffer receiving a null-terminated failure diagnostic.
 * \param[in]  error_size  Capacity of \p error in bytes, including the null terminator.
 *
 * \returns A cardano-c status represented as an int. On success, \p confirmed contains the
 *          confirmation result. On failure, the bridge preserves the original Haskell exception
 *          or expected failure for the operation that initiated the callback.
 *
 * \note The native adapter provides a non-NULL error buffer with positive capacity. The callback
 *       must not write beyond that capacity or release any borrowed input or output storage.
 */
typedef int (*cometa_confirmation_callback_t)(
  HsStablePtr          state,
  const unsigned char* hash,
  size_t               hash_size,
  uint64_t             timeout_ms,
  int*                 confirmed,
  char*                error,
  size_t               error_size);

/* FUNCTIONS *****************************************************************/

/**
 * \brief Creates a native provider that owns a Haskell confirmation callback registration.
 *
 * The returned provider owns one reference to an implementation context containing both runtime
 * handles. Final context destruction releases the function pointer and stable pointer through HsFFI.
 *
 * \param[in]  state     Stable pointer to the Haskell callback state. Must not be NULL.
 * \param[in]  callback  Haskell callback trampoline. Must not be NULL.
 * \param[out] provider  Pointer receiving one owned provider reference. Must not be NULL.
 *
 * \returns An unsigned status value: CARDANO_SUCCESS on success, CARDANO_ERROR_POINTER_IS_NULL for a NULL argument, or
 *          CARDANO_ERROR_MEMORY_ALLOCATION_FAILED if context or provider allocation fails.
 *
 * \note On success, ownership of both runtime handles transfers to the native context. On failure,
 *       neither handle transfers; the caller must release both. When all arguments are non-NULL,
 *       the output slot is initialized to NULL before allocation.
 */
unsigned int cometa_provider_new(
  HsStablePtr                    state,
  cometa_confirmation_callback_t callback,
  cardano_provider_t**           provider);

/**
 * \brief Acquires another owned reference to a provider.
 *
 * \param[in] provider Provider whose reference count is incremented. NULL has no effect.
 *
 * \note Native reference counts are not atomic. The Haskell adapter serializes reference-count
 *       transitions for every alias of a provider through a shared ownership lock.
 */
void cometa_provider_ref(cardano_provider_t* provider);

/**
 * \brief Consumes one owned provider reference through a unary destructor adapter.
 *
 * This function releases exactly one reference even when another owner keeps the provider alive.
 * The caller must separately invalidate its local handle instead of relying on pointer nullness.
 *
 * \param[in] provider Provider reference to release. NULL has no effect.
 *
 * \note Each operation retains its own provider reference until its native worker has finished.
 *       Final context destruction releases runtime handles without invoking user cleanup code.
 */
void cometa_provider_release(cardano_provider_t* provider);

/**
 * \brief Invokes native transaction confirmation without exposing native bool layout to Haskell.
 *
 * This synchronous adapter constructs a native hash, invokes the provider, and releases the hash
 * before returning. The provider and input bytes remain borrowed for the complete call.
 *
 * \param[in]  provider    Provider created by \ref cometa_provider_new. Must not be NULL.
 * \param[in]  hash        Transaction identifier bytes. Must not be NULL.
 * \param[in]  hash_size   Number of bytes available at \p hash. The Haskell adapter validates 32 bytes.
 * \param[in]  timeout_ms  Confirmation timeout in milliseconds.
 * \param[out] confirmed   Pointer receiving 0 or 1. Must not be NULL. Initialized to 0 after argument validation.
 *
 * \returns An unsigned status value: CARDANO_ERROR_POINTER_IS_NULL for a NULL argument, or the status returned by hash
 *          construction or native transaction confirmation.
 *
 * \note The caller must retain an operation reference until this call returns, including during
 *       callback cancellation. A timeout does not authorize releasing state still used by C.
 */
unsigned int cometa_provider_confirm(
  cardano_provider_t*  provider,
  const unsigned char* hash,
  size_t               hash_size,
  uint64_t             timeout_ms,
  int*                 confirmed);

/**
 * \brief Borrows the provider's last native failure diagnostic.
 *
 * \param[in] provider Provider whose diagnostic is requested. Must not be NULL and must remain valid until the string is copied.
 *
 * \returns A borrowed, null-terminated string owned by the provider. The caller must not modify or free it.
 *
 * \note Copy the string before releasing its owner or starting another operation that may overwrite it.
 */
const char* cometa_provider_error(const cardano_provider_t* provider);

/**
 * \brief Retrieves a native status diagnostic through the explicit unsigned status ABI.
 *
 * \param[in] code Numeric status converted to the native enum inside this adapter.
 *
 * \returns A borrowed static diagnostic string. The caller must not modify or free it.
 */
const char* cometa_error_message(unsigned int code);

/**
 * \brief Retrieves the process-wide number of live callback contexts.
 *
 * \returns The number of successfully adopted contexts whose final native destruction has not completed.
 *
 * \note This private diagnostic uses a C11 atomic counter so independent providers can run concurrently.
 */
size_t cometa_callback_live_contexts(void);

/**
 * \brief Retrieves the process-wide number of completed native confirmation calls.
 *
 * \returns The number of calls that completed native confirmation dispatch and temporary hash cleanup.
 *
 * \note This private atomic counter provides unwind evidence for tests. Calls rejected for NULL arguments
 *       do not increment it; calls whose hash construction fails do increment it.
 */
size_t cometa_callback_completed_calls(void);

#ifdef __cplusplus
}
#endif /* __cplusplus */

#endif // BIGLUP_LABS_INCLUDE_COMETA_PROVIDER_H
