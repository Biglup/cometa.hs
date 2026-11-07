/**
 * \file cometa_cip8.c
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
#include "cometa_cip8.h"
#include <cardano/address/address.h>
#include <cardano/crypto/blake2b_hash.h>
#include <cardano/message_signing/cip8.h>

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_cip8_sign(const cardano_ed25519_private_key_t* key, unsigned int kind, const unsigned char* binding, size_t binding_size, const unsigned char* message, size_t message_size, cardano_buffer_t** sign1, cardano_buffer_t** cose_key)
{
  if ((sign1 == NULL) || (cose_key == NULL))
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }

  *sign1    = NULL;
  *cose_key = NULL;

  cardano_address_t*      address = NULL;
  cardano_blake2b_hash_t* hash    = NULL;
  cardano_error_t         result  = CARDANO_ERROR_INVALID_ARGUMENT;

  if (kind == 0U)
  {
    result = cardano_address_from_bytes(binding, binding_size, &address);

    if (result == CARDANO_SUCCESS)
    {
      result = cardano_cip8_sign(message, message_size, address, key, sign1, cose_key);
    }
  }
  else if ((kind == 1U) && (binding_size == 28U))
  {
    result = cardano_blake2b_hash_from_bytes(binding, binding_size, &hash);

    if (result == CARDANO_SUCCESS)
    {
      result = cardano_cip8_sign_ex(message, message_size, hash, key, sign1, cose_key);
    }
  }

  cardano_address_unref(&address);
  cardano_blake2b_hash_unref(&hash);

  return (unsigned int)result;
}
