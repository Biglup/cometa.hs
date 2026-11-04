/**
 * \file cometa_signing_key.c
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

#include "cometa_signing_key.h"
#include <cardano/crypto/ed25519_public_key.h>
#include <cardano/crypto/ed25519_signature.h>
#include <stdint.h>

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_signing_key_from_normal_bytes(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_ed25519_private_key_from_normal_bytes(data, size, key);
}

unsigned int
cometa_signing_key_from_extended_bytes(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_ed25519_private_key_from_extended_bytes(data, size, key);
}

unsigned int
cometa_signing_key_from_normal_hex(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_ed25519_private_key_from_normal_hex((const char*)data, size, key);
}

unsigned int
cometa_signing_key_from_extended_hex(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_ed25519_private_key_from_extended_hex((const char*)data, size, key);
}

unsigned int
cometa_signing_key_clone(const cardano_ed25519_private_key_t* source, cardano_ed25519_private_key_t** copy)
{
  *copy = NULL;
  return (unsigned int)cardano_ed25519_private_key_deep_clone(source, copy);
}

void
cometa_signing_key_unref(cardano_ed25519_private_key_t** key)
{
  cardano_ed25519_private_key_unref(key);
}

const unsigned char*
cometa_signing_key_data(const cardano_ed25519_private_key_t* key)
{
  return cardano_ed25519_private_key_get_data(key);
}

size_t
cometa_signing_key_size(const cardano_ed25519_private_key_t* key)
{
  return cardano_ed25519_private_key_get_bytes_size(key);
}

unsigned int
cometa_signing_key_public_key(const cardano_ed25519_private_key_t* key, unsigned char* output)
{
  cardano_ed25519_public_key_t* public_key = NULL;
  cardano_error_t               result     = cardano_ed25519_private_key_get_public_key(key, &public_key);

  if (result == CARDANO_SUCCESS)
  {
    result = public_key == NULL ? CARDANO_ERROR_GENERIC : cardano_ed25519_public_key_to_bytes(public_key, output, 32U);
  }

  cardano_ed25519_public_key_unref(&public_key);
  return (unsigned int)result;
}

unsigned int
cometa_signing_key_sign(const cardano_ed25519_private_key_t* key, const unsigned char* message, size_t size, unsigned char* output)
{
  if ((message == NULL) && (size != 0U))
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }

  /* Native extended signing forms buffers of size message_length + 64. */
  if (size > SIZE_MAX - 64U)
  {
    return (unsigned int)CARDANO_ERROR_INTEGER_OVERFLOW;
  }

  static const unsigned char   empty_message = 0U;
  cardano_ed25519_signature_t* signature     = NULL;
  cardano_error_t              result        = cardano_ed25519_private_key_sign(key, message == NULL ? &empty_message : message, size, &signature);

  if (result == CARDANO_SUCCESS)
  {
    result = signature == NULL ? CARDANO_ERROR_GENERIC : cardano_ed25519_signature_to_bytes(signature, output, 64U);
  }

  cardano_ed25519_signature_unref(&signature);
  return (unsigned int)result;
}
