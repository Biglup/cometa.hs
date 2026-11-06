/**
 * \file pool_oracle.c
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
#include <stdlib.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/** \brief Rebuilds metadata; the getter retains hash, all text is borrowed. */
static cardano_error_t
rebuild_metadata(cardano_pool_metadata_t* source, cardano_pool_metadata_t** output)
{
  cardano_blake2b_hash_t* hash   = NULL;
  cardano_error_t         result = cardano_pool_metadata_get_hash(source, &hash);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_metadata_new(cardano_pool_metadata_get_url(source), cardano_pool_metadata_get_url_size(source), hash, output);
  }
  cardano_blake2b_hash_unref(&hash);
  return result;
}

/** \brief Rebuilds BLS fields from borrowed, length-delimited byte snapshots. */
static cardano_error_t
rebuild_bls(cardano_bls_key_t* source, cardano_bls_key_t** output)
{
  return cardano_bls_key_new(cardano_bls_key_get_public_key_bytes(source), cardano_bls_key_get_public_key_size(source), cardano_bls_key_get_possession_proof_bytes(source), cardano_bls_key_get_possession_proof_size(source), output);
}

/** \brief Rebuilds an IP relay. Every getter output is retained and released. */
static cardano_error_t
rebuild_address_relay(cardano_relay_t* source, cardano_relay_t** output)
{
  cardano_single_host_addr_relay_t* address = NULL;
  cardano_single_host_addr_relay_t* fresh   = NULL;
  cardano_ipv4_t*                   ipv4    = NULL;
  cardano_ipv6_t*                   ipv6    = NULL;
  cardano_error_t                   result  = cardano_relay_to_single_host_addr(source, &address);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_single_host_addr_relay_get_ipv4(address, &ipv4);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_single_host_addr_relay_get_ipv6(address, &ipv6);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_single_host_addr_relay_new(cardano_single_host_addr_relay_get_port(address), ipv4, ipv6, &fresh);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_relay_new_single_host_addr(fresh, output);
  }
  cardano_ipv4_unref(&ipv4);
  cardano_ipv6_unref(&ipv6);
  cardano_single_host_addr_relay_unref(&fresh);
  cardano_single_host_addr_relay_unref(&address);
  return result;
}

/** \brief Rebuilds DNS alternatives using borrowed text; outputs own refs. */
static cardano_error_t
rebuild_relay(cardano_relay_t* source, cardano_relay_t** output)
{
  cardano_relay_type_t              type        = CARDANO_RELAY_TYPE_SINGLE_HOST_ADDRESS;
  cardano_single_host_name_relay_t* name        = NULL;
  cardano_single_host_name_relay_t* fresh_name  = NULL;
  cardano_multi_host_name_relay_t*  multi       = NULL;
  cardano_multi_host_name_relay_t*  fresh_multi = NULL;
  cardano_error_t                   result      = cardano_relay_get_type(source, &type);
  if (result != CARDANO_SUCCESS)
  {
    return result;
  }
  if (type == CARDANO_RELAY_TYPE_SINGLE_HOST_ADDRESS)
  {
    return rebuild_address_relay(source, output);
  }
  if (type == CARDANO_RELAY_TYPE_SINGLE_HOST_NAME)
  {
    result = cardano_relay_to_single_host_name(source, &name);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_single_host_name_relay_new(cardano_single_host_name_relay_get_port(name), cardano_single_host_name_relay_get_dns(name), cardano_single_host_name_relay_get_dns_size(name) - 1U, &fresh_name);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_relay_new_single_host_name(fresh_name, output);
    }
  }
  else
  {
    result = cardano_relay_to_multi_host_name(source, &multi);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_multi_host_name_relay_new(cardano_multi_host_name_relay_get_dns(multi), cardano_multi_host_name_relay_get_dns_size(multi) - 1U, &fresh_multi);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_relay_new_multi_host_name(fresh_multi, output);
    }
  }
  cardano_single_host_name_relay_unref(&name);
  cardano_single_host_name_relay_unref(&fresh_name);
  cardano_multi_host_name_relay_unref(&multi);
  cardano_multi_host_name_relay_unref(&fresh_multi);
  return result;
}

/** \brief Rebuilds ordered relays. Each acquired loop reference is released. */
static cardano_error_t
rebuild_relays(cardano_relays_t* source, cardano_relays_t** output)
{
  cardano_error_t result = cardano_relays_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_relays_get_length(source); ++i)
  {
    cardano_relay_t* relay = NULL;
    cardano_relay_t* fresh = NULL;
    result                 = cardano_relays_get(source, i, &relay);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_relay(relay, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_relays_add(*output, fresh);
    }
    cardano_relay_unref(&fresh);
    cardano_relay_unref(&relay);
  }
  return result;
}

/** \brief Rebuilds sorted owners from retained hash getters. */
static cardano_error_t
rebuild_owners(cardano_pool_owners_t* source, cardano_pool_owners_t** output)
{
  cardano_error_t result = cardano_pool_owners_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_pool_owners_get_length(source); ++i)
  {
    cardano_blake2b_hash_t* hash = NULL;
    result                       = cardano_pool_owners_get(source, i, &hash);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_pool_owners_add(*output, hash);
    }
    cardano_blake2b_hash_unref(&hash);
  }
  return result;
}

/**
 * \brief Rebuilds parameters using retained field getters and constructors.
 * All local objects own references. The output owns only references adopted by
 * successful native constructors; locals are released on every failure path.
 */
static cardano_error_t
rebuild_parameters(cardano_pool_params_t* source, cardano_pool_params_t** output)
{
  cardano_blake2b_hash_t*   operator_hash  = NULL;
  cardano_blake2b_hash_t*   vrf            = NULL;
  cardano_unit_interval_t*  margin         = NULL;
  cardano_reward_address_t* reward         = NULL;
  cardano_pool_owners_t*    owners         = NULL;
  cardano_pool_owners_t*    fresh_owners   = NULL;
  cardano_relays_t*         relays         = NULL;
  cardano_relays_t*         fresh_relays   = NULL;
  cardano_pool_metadata_t*  metadata       = NULL;
  cardano_pool_metadata_t*  fresh_metadata = NULL;
  cardano_bls_key_t*        bls            = NULL;
  cardano_bls_key_t*        fresh_bls      = NULL;
  uint64_t                  pledge         = 0;
  uint64_t                  cost           = 0;
  cardano_error_t           result         = cardano_pool_params_get_operator_key_hash(source, &operator_hash);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_vrf_vk_hash(source, &vrf);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_pledge(source, &pledge);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_cost(source, &cost);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_margin(source, &margin);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_reward_account(source, &reward);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_owners(source, &owners);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = rebuild_owners(owners, &fresh_owners);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_relays(source, &relays);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = rebuild_relays(relays, &fresh_relays);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_metadata(source, &metadata);
  }
  if (result == CARDANO_SUCCESS && metadata != NULL)
  {
    result = rebuild_metadata(metadata, &fresh_metadata);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_new(operator_hash, vrf, pledge, cost, margin, reward, fresh_owners, fresh_relays, fresh_metadata, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_get_bls_key(source, &bls);
  }
  if (result == CARDANO_SUCCESS && bls != NULL)
  {
    result = rebuild_bls(bls, &fresh_bls);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_params_set_bls_key(*output, fresh_bls);
  }
  cardano_bls_key_unref(&fresh_bls);
  cardano_bls_key_unref(&bls);
  cardano_pool_metadata_unref(&fresh_metadata);
  cardano_pool_metadata_unref(&metadata);
  cardano_relays_unref(&fresh_relays);
  cardano_relays_unref(&relays);
  cardano_pool_owners_unref(&fresh_owners);
  cardano_pool_owners_unref(&owners);
  cardano_reward_address_unref(&reward);
  cardano_unit_interval_unref(&margin);
  cardano_blake2b_hash_unref(&vrf);
  cardano_blake2b_hash_unref(&operator_hash);
  return result;
}

/* DEFINITIONS ***************************************************************/

/**
 * \brief Compares public Haskell serialization with native field reconstruction.
 * The standalone Haskell parameter array is stripped and restored explicitly;
 * the native parameter codec consumes a flat embedded group.
 * \param mode 0 parameters, 1 relay, 2 metadata, 3 BLS key.
 * \param input Borrowed encoded bytes, valid throughout this call.
 * \param size Exact byte count.
 * \return One for exact agreement, zero for any native failure or difference.
 */
int
cometa_test_pool_agreement(unsigned int mode, const unsigned char* input, size_t size)
{
  if (size == 0 || (mode == 0 && input[0] != 0x89 && input[0] != 0x8a))
  {
    return 0;
  }
  const size_t           framing = mode == 0 ? 1U : 0U;
  cardano_cbor_reader_t* reader  = cardano_cbor_reader_new(input + framing, size - framing);
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_buffer_t*      encoded = NULL;
  cardano_error_t        result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  int                    agrees  = 0;
  if (reader == NULL || writer == NULL)
  {
    goto cleanup;
  }
  if (mode == 0)
  {
    cardano_pool_params_t* source = NULL;
    cardano_pool_params_t* fresh  = NULL;
    result                        = cardano_cbor_writer_write_start_array(writer, (int64_t)(input[0] & 31U));
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_pool_params_from_cbor(reader, &source);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_parameters(source, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_pool_params_to_cbor(fresh, writer);
    }
    cardano_pool_params_unref(&fresh);
    cardano_pool_params_unref(&source);
  }
  else if (mode == 1)
  {
    cardano_relay_t* source = NULL;
    cardano_relay_t* fresh  = NULL;
    result                  = cardano_relay_from_cbor(reader, &source);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_relay(source, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_relay_to_cbor(fresh, writer);
    }
    cardano_relay_unref(&fresh);
    cardano_relay_unref(&source);
  }
  else if (mode == 2)
  {
    cardano_pool_metadata_t* source = NULL;
    cardano_pool_metadata_t* fresh  = NULL;
    result                          = cardano_pool_metadata_from_cbor(reader, &source);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_metadata(source, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_pool_metadata_to_cbor(fresh, writer);
    }
    cardano_pool_metadata_unref(&fresh);
    cardano_pool_metadata_unref(&source);
  }
  else if (mode == 3)
  {
    cardano_bls_key_t* source = NULL;
    cardano_bls_key_t* fresh  = NULL;
    result                    = cardano_bls_key_from_cbor(reader, &source);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_bls(source, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_bls_key_to_cbor(fresh, writer);
    }
    cardano_bls_key_unref(&fresh);
    cardano_bls_key_unref(&source);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  }
  if (result == CARDANO_SUCCESS)
  {
    agrees = cardano_buffer_get_size(encoded) == size && memcmp(cardano_buffer_get_data(encoded), input, size) == 0;
  }
cleanup:
  cardano_buffer_unref(&encoded);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return agrees;
}
