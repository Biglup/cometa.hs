/**
 * \file cometa_ed25519_values.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_ED25519_VALUES_H
#define BIGLUP_LABS_INCLUDE_COMETA_ED25519_VALUES_H

/* INCLUDES ******************************************************************/

#include <cardano/crypto/blake2b_hash.h>
#include <stddef.h>

/* DECLARATIONS **************************************************************/

#ifdef __cplusplus
extern "C" {
#endif /* __cplusplus */

/**
 * \brief Verifies a detached Ed25519 signature using operation-scoped native values.
 *
 * All input spans are borrowed until return. Public key and signature objects are constructed
 * locally and released on every path, including when the second constructor fails. No native
 * object or borrowed storage survives the call. Native bool does not cross the Haskell ABI.
 *
 * \param[in] public_key Public key bytes. Must not be NULL.
 * \param[in] public_key_size Number of public key bytes; native import requires 32.
 * \param[in] signature Signature bytes. Must not be NULL.
 * \param[in] signature_size Number of signature bytes; native import requires 64.
 * \param[in] message Exact message bytes. NULL is accepted only when message_size is zero.
 * \param[in] message_size Message length in bytes, including embedded NUL bytes.
 * \param[out] verified Receives 1 when verification succeeds and 0 otherwise. Must not be NULL.
 *
 * \returns A cardano-c status converted to unsigned int. Invalid signatures produce CARDANO_SUCCESS
 *          with output zero; import and allocation failures preserve their native status.
 *
 * \note The native verifier also returns false when its cryptographic backend cannot initialize.
 *       Its Boolean interface provides no distinct status for that condition.
 */
unsigned int cometa_ed25519_verify(
  const unsigned char* public_key,
  size_t               public_key_size,
  const unsigned char* signature,
  size_t               signature_size,
  const unsigned char* message,
  size_t               message_size,
  int*                 verified);

/**
 * \brief Computes the native BLAKE2b-224 digest of encoded public key bytes.
 *
 * The public key is borrowed, imported into one local native object, and released before return.
 * The returned hash is an owned result; its reference is not consumed with the temporary key.
 *
 * \param[in] public_key Public key bytes. Must not be NULL.
 * \param[in] public_key_size Number of public key bytes; native import requires 32.
 * \param[out] hash Receives one owned hash reference. Must not be NULL and must not overwrite an owner.
 *
 * \returns A cardano-c status converted to unsigned int. The hash slot is initialized to NULL before
 *          import. The caller releases any result reference, including a partial failure result.
 */
unsigned int cometa_ed25519_public_key_hash(
  const unsigned char*     public_key,
  size_t                   public_key_size,
  cardano_blake2b_hash_t** hash);

#ifdef __cplusplus
}
#endif /* __cplusplus */

#endif // BIGLUP_LABS_INCLUDE_COMETA_ED25519_VALUES_H
