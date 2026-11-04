/**
 * \file cometa_ed25519_values.c
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

#include "cometa_ed25519_values.h"

#include <cardano/crypto/ed25519_public_key.h>
#include <cardano/crypto/ed25519_signature.h>

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_ed25519_verify(
  const unsigned char* public_key,
  size_t               public_key_size,
  const unsigned char* signature,
  size_t               signature_size,
  const unsigned char* message,
  size_t               message_size,
  int*                 verified)
{
  if (verified == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  *verified = 0;

  if ((message == NULL) && (message_size != 0U))
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  cardano_ed25519_public_key_t* native_key       = NULL;
  cardano_ed25519_signature_t*  native_signature = NULL;
  cardano_error_t               result           = cardano_ed25519_public_key_from_bytes(public_key, public_key_size, &native_key);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_ed25519_signature_from_bytes(signature, signature_size, &native_signature);
  }

  if (result == CARDANO_SUCCESS)
  {
    *verified = cardano_ed25519_public_verify(native_key, native_signature, message, message_size) ? 1 : 0;
  }

  cardano_ed25519_signature_unref(&native_signature);
  cardano_ed25519_public_key_unref(&native_key);

  return (unsigned int)result;
}

unsigned int
cometa_ed25519_public_key_hash(
  const unsigned char*     public_key,
  size_t                   public_key_size,
  cardano_blake2b_hash_t** hash)
{
  if (hash == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  *hash = NULL;

  cardano_ed25519_public_key_t* native_key = NULL;
  cardano_error_t               result     = cardano_ed25519_public_key_from_bytes(public_key, public_key_size, &native_key);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_ed25519_public_key_to_hash(native_key, hash);
  }

  cardano_ed25519_public_key_unref(&native_key);

  return (unsigned int)result;
}
