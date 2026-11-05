/**
 * \file address_oracle.c
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

#include <cardano/address/address.h>
#include <cardano/address/base_address.h>
#include <cardano/address/enterprise_address.h>
#include <cardano/address/reward_address.h>
#include <cardano/common/credential.h>
#include <cardano/encoding/bech32.h>

#include <string.h>

/* DEFINITIONS ***************************************************************/

/* Reconstruct a native address from credential fields, compare native bytes and
 * type/network inspection, then release each independently owned reference.
 * Only supported exact-length Haskell test fixtures reach this helper. */
int
cometa_test_address_agreement(const unsigned char* bytes, size_t size, const unsigned char* text, size_t text_size)
{
  const unsigned int            tag        = bytes[0] >> 4;
  const cardano_network_id_t    network    = (cardano_network_id_t)(bytes[0] & 15U);
  cardano_credential_t*         payment    = NULL;
  cardano_credential_t*         stake      = NULL;
  cardano_base_address_t*       base       = NULL;
  cardano_enterprise_address_t* enterprise = NULL;
  cardano_reward_address_t*     reward     = NULL;
  cardano_address_t*            address    = NULL;
  cardano_error_t               result     = CARDANO_SUCCESS;

  if (tag < 14U)
  {
    result = cardano_credential_from_hash_bytes(bytes + 1, 28, (cardano_credential_type_t)(tag & 1U), &payment);
  }

  if ((result == CARDANO_SUCCESS) && ((tag < 4U) || (tag >= 14U)))
  {
    result = cardano_credential_from_hash_bytes(bytes + ((tag < 4U) ? 29 : 1), 28, (cardano_credential_type_t)((tag < 4U) ? ((tag >> 1) & 1U) : (tag & 1U)), &stake);
  }

  if (result == CARDANO_SUCCESS)
  {
    if (tag < 4U)
    {
      result = cardano_base_address_from_credentials(network, payment, stake, &base);

      if (result == CARDANO_SUCCESS)
        address = cardano_base_address_to_address(base);
    }
    else if (tag < 14U)
    {
      result = cardano_enterprise_address_from_credentials(network, payment, &enterprise);

      if (result == CARDANO_SUCCESS)
        address = cardano_enterprise_address_to_address(enterprise);
    }
    else
    {
      result = cardano_reward_address_from_credentials(network, stake, &reward);

      if (result == CARDANO_SUCCESS)
        address = cardano_reward_address_to_address(reward);
    }
  }

  cardano_address_type_t actual_type;
  cardano_network_id_t   actual_network;
  int                    agrees = 0;

  if ((result == CARDANO_SUCCESS) && (address != NULL))
  {
    const cardano_error_t type_result    = cardano_address_get_type(address, &actual_type);
    const cardano_error_t network_result = cardano_address_get_network_id(address, &actual_network);
    agrees                               = (type_result == CARDANO_SUCCESS) && (network_result == CARDANO_SUCCESS) &&
      ((unsigned int)actual_type == tag) && (actual_network == network) &&
      (cardano_address_get_bytes_size(address) == size) &&
      (memcmp(cardano_address_get_bytes(address), bytes, size) == 0) &&
      (cardano_address_get_string_size(address) == text_size + 1U) &&
      (memcmp(cardano_address_get_string(address), text, text_size) == 0);
  }

  cardano_address_unref(&address);
  cardano_base_address_unref(&base);
  cardano_enterprise_address_unref(&enterprise);
  cardano_reward_address_unref(&reward);
  cardano_credential_unref(&payment);
  cardano_credential_unref(&stake);

  return agrees;
}

/* Test-only arbitrary HRP encoder: produce valid-checksum hostile inputs rather
 * than conflating an HRP mismatch with a checksum failure. Spans are borrowed. */
unsigned int
cometa_test_address_bech32(const char* hrp, const unsigned char* bytes, size_t size, unsigned char* output, size_t capacity)
{
  return (unsigned int)cardano_encoding_bech32_encode(hrp, strlen(hrp), bytes, size, (char*)output, capacity);
}
