/**
 * \file cometa_key_handler.c
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
#include "cometa_key_handler.h"

/* DEFINITIONS ***************************************************************/
unsigned int
cometa_handler_account(cardano_secure_key_handler_t* handler, uint32_t purpose, uint32_t coin, uint32_t account, unsigned char* output)
{
  cardano_account_derivation_path_t path   = { purpose, coin, account };
  cardano_bip32_public_key_t*       key    = NULL;
  cardano_error_t                   result = cardano_secure_key_handler_bip32_get_extended_account_public_key(handler, path, &key);
  if (result == CARDANO_SUCCESS)
  {
    result = key == NULL ? CARDANO_ERROR_GENERIC : cardano_bip32_public_key_to_bytes(key, output, 64U);
  }
  cardano_bip32_public_key_unref(&key);
  return (unsigned int)result;
}

unsigned int
cometa_handler_public(cardano_secure_key_handler_t* handler, unsigned char* output)
{
  cardano_ed25519_public_key_t* key    = NULL;
  cardano_error_t               result = cardano_secure_key_handler_ed25519_get_public_key(handler, &key);
  if (result == CARDANO_SUCCESS)
  {
    result = key == NULL ? CARDANO_ERROR_GENERIC : cardano_ed25519_public_key_to_bytes(key, output, 32U);
  }
  cardano_ed25519_public_key_unref(&key);
  return (unsigned int)result;
}
