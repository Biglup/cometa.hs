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
#include <cardano/cbor/cbor_reader.h>
#include <cardano/cbor/cbor_writer.h>
#include <cardano/transaction/sub_transaction.h>
#include <cardano/transaction/transaction.h>
#include <stdlib.h>

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

unsigned int
cometa_handler_sign(cardano_secure_key_handler_t* handler, const unsigned char* bytes, size_t size, unsigned int kind, const uint32_t* components, size_t count, cardano_buffer_t** output)
{
  if (output == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output = NULL;
  if ((handler == NULL) || (bytes == NULL) || (size == 0U) || (kind > 3U))
  {
    return (unsigned int)CARDANO_ERROR_INVALID_ARGUMENT;
  }
  const bool bip32 = (kind & 1U) != 0U;
  const bool sub   = (kind & 2U) != 0U;
  if (bip32 && ((components == NULL) || (count == 0U) || (count > SIZE_MAX / sizeof(cardano_derivation_path_t))))
  {
    return (unsigned int)CARDANO_ERROR_INVALID_ARGUMENT;
  }
  cardano_derivation_path_t* paths = bip32 ? calloc(count, sizeof(cardano_derivation_path_t)) : NULL;
  if (bip32 && (paths == NULL))
  {
    return (unsigned int)CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  for (size_t i = 0U; bip32 && (i < count); ++i)
  {
    paths[i].purpose   = components[5U * i];
    paths[i].coin_type = components[5U * i + 1U];
    paths[i].account   = components[5U * i + 2U];
    paths[i].role      = components[5U * i + 3U];
    paths[i].index     = components[5U * i + 4U];
  }
  cardano_cbor_reader_t*      reader          = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_writer_t*      writer          = NULL;
  cardano_transaction_t*      transaction     = NULL;
  cardano_sub_transaction_t*  sub_transaction = NULL;
  cardano_vkey_witness_set_t* vkeys           = NULL;
  cardano_witness_set_t*      witnesses       = NULL;
  cardano_error_t             result          = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;
  size_t                      remaining       = 0U;
  if (result == CARDANO_SUCCESS)
  {
    result = sub ? cardano_sub_transaction_from_cbor(reader, &sub_transaction) : cardano_transaction_from_cbor(reader, &transaction);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
    if ((result == CARDANO_SUCCESS) && (remaining != 0U))
    {
      result = CARDANO_ERROR_DECODING;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    if (sub)
    {
      result = bip32 ? cardano_secure_key_handler_bip32_sign_sub_transaction(handler, sub_transaction, paths, count, &vkeys)
                     : cardano_secure_key_handler_ed25519_sign_sub_transaction(handler, sub_transaction, &vkeys);
    }
    else
    {
      result = bip32 ? cardano_secure_key_handler_bip32_sign_transaction(handler, transaction, paths, count, &vkeys)
                     : cardano_secure_key_handler_ed25519_sign_transaction(handler, transaction, &vkeys);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = vkeys == NULL ? CARDANO_ERROR_GENERIC : cardano_witness_set_new(&witnesses);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_witness_set_set_vkeys(witnesses, vkeys);
  }
  if (result == CARDANO_SUCCESS)
  {
    writer = cardano_cbor_writer_new();
    result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_witness_set_to_cbor(witnesses, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  cardano_transaction_unref(&transaction);
  cardano_sub_transaction_unref(&sub_transaction);
  cardano_vkey_witness_set_unref(&vkeys);
  cardano_witness_set_unref(&witnesses);
  free(paths);
  if (result != CARDANO_SUCCESS)
  {
    cardano_buffer_unref(output);
    *output = NULL;
  }
  return (unsigned int)result;
}
