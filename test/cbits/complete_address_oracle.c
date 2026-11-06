/**
 * \file certificates_oracle.c
 *
 * \author angel.castillo
 * \date   Nov 05, 2026
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
#include <cardano/cardano.h>
#include <string.h>

/* Getter ownership audited in address/{byron,pointer}_address.c: Byron root
 * allocates a hash; attributes and pointer fields copy scalars; payment retains
 * a credential. Both to_address conversions allocate independent addresses. */
int
cometa_test_complete_address_agree(unsigned int kind, const unsigned char* bytes, size_t size, const unsigned char* text, size_t text_size)
{
  cardano_address_t* fresh  = NULL;
  cardano_error_t    result = CARDANO_SUCCESS;
  int                agrees = 0;
  if (kind == 0)
  {
    cardano_byron_address_t*           old        = NULL;
    cardano_byron_address_t*           rebuilt    = NULL;
    cardano_blake2b_hash_t*            root       = NULL;
    cardano_byron_address_attributes_t attributes = { 0 };
    cardano_byron_address_type_t       type       = CARDANO_BYRON_ADDRESS_TYPE_PUBKEY;
    result                                        = cardano_byron_address_from_bytes(bytes, size, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_byron_address_get_root(old, &root);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_byron_address_get_attributes(old, &attributes);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_byron_address_get_type(old, &type);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_byron_address_from_credentials(root, attributes, type, &rebuilt);
    }
    if (result == CARDANO_SUCCESS)
    {
      fresh = cardano_byron_address_to_address(rebuilt);
    }
    cardano_blake2b_hash_unref(&root);
    cardano_byron_address_unref(&rebuilt);
    cardano_byron_address_unref(&old);
  }
  else if (kind == 1)
  {
    cardano_pointer_address_t* old     = NULL;
    cardano_pointer_address_t* rebuilt = NULL;
    cardano_credential_t*      payment = NULL;
    cardano_stake_pointer_t    pointer = { 0 };
    cardano_network_id_t       network = 0;
    result                             = cardano_pointer_address_from_bytes(bytes, size, &old);
    if (result == CARDANO_SUCCESS)
    {
      payment = cardano_pointer_address_get_payment_credential(old);
      result  = cardano_pointer_address_get_stake_pointer(old, &pointer);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_pointer_address_get_network_id(old, &network);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_pointer_address_from_credentials(network, payment, pointer, &rebuilt);
    }
    if (result == CARDANO_SUCCESS)
    {
      fresh = cardano_pointer_address_to_address(rebuilt);
    }
    cardano_credential_unref(&payment);
    cardano_pointer_address_unref(&rebuilt);
    cardano_pointer_address_unref(&old);
  }
  else
  {
    return 0;
  }
  if (result == CARDANO_SUCCESS && fresh != NULL)
  {
    agrees = cardano_address_get_bytes_size(fresh) == size &&
      memcmp(cardano_address_get_bytes(fresh), bytes, size) == 0 &&
      cardano_address_get_string_size(fresh) == text_size + 1U &&
      memcmp(cardano_address_get_string(fresh), text, text_size) == 0;
  }
  cardano_address_unref(&fresh);
  return agrees;
}
