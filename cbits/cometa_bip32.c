/**
 * \file cometa_bip32.c
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

#include "cometa_bip32.h"
#include <cardano/crypto/bip32_public_key.h>

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_bip32_from_bytes(const unsigned char* data, size_t size, cardano_bip32_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_bip32_private_key_from_bytes(data, size, key);
}

unsigned int
cometa_bip32_from_hex(const unsigned char* data, size_t size, cardano_bip32_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_bip32_private_key_from_hex((const char*)data, size, key);
}

unsigned int
cometa_bip32_from_entropy(const unsigned char* password, size_t password_size, const unsigned char* entropy, size_t entropy_size, cardano_bip32_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_bip32_private_key_from_bip39_entropy(password, password_size, entropy, entropy_size, key);
}

unsigned int
cometa_bip32_clone(const cardano_bip32_private_key_t* source, cardano_bip32_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_bip32_private_key_deep_clone(source, key);
}

unsigned int
cometa_bip32_derive(const cardano_bip32_private_key_t* source, const uint32_t* indices, size_t count, cardano_bip32_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_bip32_private_key_derive(source, indices, count, key);
}

unsigned int
cometa_bip32_to_signing_key(const cardano_bip32_private_key_t* source, cardano_ed25519_private_key_t** key)
{
  *key = NULL;
  return (unsigned int)cardano_bip32_private_key_to_ed25519_key(source, key);
}

void
cometa_bip32_unref(cardano_bip32_private_key_t** key)
{
  cardano_bip32_private_key_unref(key);
}

const unsigned char*
cometa_bip32_data(const cardano_bip32_private_key_t* key)
{
  return cardano_bip32_private_key_get_data(key);
}

size_t
cometa_bip32_size(const cardano_bip32_private_key_t* key)
{
  return cardano_bip32_private_key_get_bytes_size(key);
}

unsigned int
cometa_bip32_public_key(const cardano_bip32_private_key_t* key, unsigned char* output)
{
  cardano_bip32_public_key_t* public_key = NULL;
  cardano_error_t             result     = cardano_bip32_private_key_get_public_key(key, &public_key);

  if (result == CARDANO_SUCCESS)
  {
    result = public_key == NULL ? CARDANO_ERROR_GENERIC : cardano_bip32_public_key_to_bytes(public_key, output, 64U);
  }

  cardano_bip32_public_key_unref(&public_key);

  return (unsigned int)result;
}

unsigned int
cometa_bip32_derive_public(const unsigned char* bytes, const uint32_t* indices, size_t count, unsigned char* output)
{
  cardano_bip32_public_key_t* source  = NULL;
  cardano_bip32_public_key_t* derived = NULL;
  cardano_error_t             result  = cardano_bip32_public_key_from_bytes(bytes, 64U, &source);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_bip32_public_key_derive(source, indices, count, &derived);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = derived == NULL ? CARDANO_ERROR_GENERIC : cardano_bip32_public_key_to_bytes(derived, output, 64U);
  }

  cardano_bip32_public_key_unref(&derived);
  cardano_bip32_public_key_unref(&source);

  return (unsigned int)result;
}
