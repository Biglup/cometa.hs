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

/* Every getter below is audited in the pinned implementation: object outputs
 * retain a reference, scalar/byte views borrow from their live owner. Fresh
 * enclosing objects are assembled without forwarding their CBOR cache. */
static cardano_error_t
rebuild_key(cardano_vkey_witness_t* source, cardano_vkey_witness_t** output)
{
  cardano_ed25519_public_key_t* key       = cardano_vkey_witness_get_vkey(source);
  cardano_ed25519_signature_t*  signature = cardano_vkey_witness_get_signature(source);
  cardano_error_t               result    = cardano_vkey_witness_new(key, signature, output);
  cardano_ed25519_signature_unref(&signature);
  cardano_ed25519_public_key_unref(&key);
  return result;
}

static cardano_error_t
rebuild_bootstrap(cardano_bootstrap_witness_t* source, cardano_bootstrap_witness_t** output)
{
  cardano_ed25519_public_key_t* key        = cardano_bootstrap_witness_get_vkey(source);
  cardano_ed25519_signature_t*  signature  = cardano_bootstrap_witness_get_signature(source);
  cardano_buffer_t*             chain      = cardano_bootstrap_witness_get_chain_code(source);
  cardano_buffer_t*             attributes = cardano_bootstrap_witness_get_attributes(source);
  cardano_error_t               result     = cardano_bootstrap_witness_new(key, signature, chain, attributes, output);
  cardano_buffer_unref(&attributes);
  cardano_buffer_unref(&chain);
  cardano_ed25519_signature_unref(&signature);
  cardano_ed25519_public_key_unref(&key);
  return result;
}

static cardano_error_t
rebuild_redeemer(cardano_redeemer_t* source, cardano_redeemer_t** output)
{
  cardano_plutus_data_t* data        = cardano_redeemer_get_data(source);
  cardano_ex_units_t*    units       = cardano_redeemer_get_ex_units(source);
  cardano_ex_units_t*    fresh_units = NULL;
  cardano_error_t        result      = cardano_ex_units_new(cardano_ex_units_get_memory(units), cardano_ex_units_get_cpu_steps(units), &fresh_units);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_redeemer_new(cardano_redeemer_get_tag(source), cardano_redeemer_get_index(source), data, fresh_units, output);
  }
  cardano_ex_units_unref(&fresh_units);
  cardano_ex_units_unref(&units);
  cardano_plutus_data_unref(&data);
  return result;
}

static cardano_error_t
rebuild_vkey_witness_set(cardano_vkey_witness_set_t* source, cardano_vkey_witness_set_t** output)
{
  cardano_error_t result = cardano_vkey_witness_set_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_vkey_witness_set_get_length(source); ++i)
  {
    cardano_vkey_witness_t* old   = NULL;
    cardano_vkey_witness_t* fresh = NULL;
    result                        = cardano_vkey_witness_set_get(source, i, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_key(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_vkey_witness_set_add(*output, fresh);
    }
    cardano_vkey_witness_unref(&fresh);
    cardano_vkey_witness_unref(&old);
  }
  return result;
}

static cardano_error_t
rebuild_bootstrap_witness_set(cardano_bootstrap_witness_set_t* source, cardano_bootstrap_witness_set_t** output)
{
  cardano_error_t result = cardano_bootstrap_witness_set_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_bootstrap_witness_set_get_length(source); ++i)
  {
    cardano_bootstrap_witness_t* old   = NULL;
    cardano_bootstrap_witness_t* fresh = NULL;
    result                             = cardano_bootstrap_witness_set_get(source, i, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_bootstrap(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_bootstrap_witness_set_add(*output, fresh);
    }
    cardano_bootstrap_witness_unref(&fresh);
    cardano_bootstrap_witness_unref(&old);
  }
  return result;
}

static cardano_error_t
rebuild_redeemer_list(cardano_redeemer_list_t* source, cardano_redeemer_list_t** output)
{
  cardano_error_t result = cardano_redeemer_list_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_redeemer_list_get_length(source); ++i)
  {
    cardano_redeemer_t* old   = NULL;
    cardano_redeemer_t* fresh = NULL;
    result                    = cardano_redeemer_list_get(source, i, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_redeemer(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_redeemer_list_add(*output, fresh);
    }
    cardano_redeemer_unref(&fresh);
    cardano_redeemer_unref(&old);
  }
  return result;
}

static cardano_error_t
rebuild_witness_set(cardano_witness_set_t* source, cardano_witness_set_t** output)
{
  cardano_error_t result = cardano_witness_set_new(output);
  if (result == CARDANO_SUCCESS)
  {
    cardano_vkey_witness_set_t* child = cardano_witness_set_get_vkeys(source);
    cardano_vkey_witness_set_t* fresh = NULL;
    if (child != NULL)
    {
      result = rebuild_vkey_witness_set(child, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_witness_set_set_vkeys(*output, fresh);
    }
    cardano_vkey_witness_set_unref(&fresh);
    cardano_vkey_witness_set_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_bootstrap_witness_set_t* child = cardano_witness_set_get_bootstrap(source);
    cardano_bootstrap_witness_set_t* fresh = NULL;
    if (child != NULL)
    {
      result = rebuild_bootstrap_witness_set(child, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_witness_set_set_bootstrap(*output, fresh);
    }
    cardano_bootstrap_witness_set_unref(&fresh);
    cardano_bootstrap_witness_set_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_redeemer_list_t* child = cardano_witness_set_get_redeemers(source);
    cardano_redeemer_list_t* fresh = NULL;
    if (child != NULL)
    {
      result = rebuild_redeemer_list(child, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_witness_set_set_redeemers(*output, fresh);
    }
    cardano_redeemer_list_unref(&fresh);
    cardano_redeemer_list_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_native_script_set_t* child = cardano_witness_set_get_native_scripts(source);
    result                             = cardano_witness_set_set_native_scripts(*output, child);
    cardano_native_script_set_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v1_script_set_t* child = cardano_witness_set_get_plutus_v1_scripts(source);
    result                                = cardano_witness_set_set_plutus_v1_scripts(*output, child);
    cardano_plutus_v1_script_set_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_data_set_t* child = cardano_witness_set_get_plutus_data(source);
    result                           = cardano_witness_set_set_plutus_data(*output, child);
    cardano_plutus_data_set_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v2_script_set_t* child = cardano_witness_set_get_plutus_v2_scripts(source);
    result                                = cardano_witness_set_set_plutus_v2_scripts(*output, child);
    cardano_plutus_v2_script_set_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v3_script_set_t* child = cardano_witness_set_get_plutus_v3_scripts(source);
    result                                = cardano_witness_set_set_plutus_v3_scripts(*output, child);
    cardano_plutus_v3_script_set_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v4_script_set_t* child = cardano_witness_set_get_plutus_v4_scripts(source);
    result                                = cardano_witness_set_set_plutus_v4_scripts(*output, child);
    cardano_plutus_v4_script_set_unref(&child);
  }
  return result;
}

static cardano_error_t
rebuild_auxiliary_data(cardano_auxiliary_data_t* source, cardano_auxiliary_data_t** output)
{
  cardano_error_t result = cardano_auxiliary_data_new(output);
  if (result == CARDANO_SUCCESS)
  {
    cardano_transaction_metadata_t* child = cardano_auxiliary_data_get_transaction_metadata(source);
    result                                = cardano_auxiliary_data_set_transaction_metadata(*output, child);
    cardano_transaction_metadata_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_native_script_list_t* child = cardano_auxiliary_data_get_native_scripts(source);
    result                              = cardano_auxiliary_data_set_native_scripts(*output, child);
    cardano_native_script_list_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v1_script_list_t* child = cardano_auxiliary_data_get_plutus_v1_scripts(source);
    result                                 = cardano_auxiliary_data_set_plutus_v1_scripts(*output, child);
    cardano_plutus_v1_script_list_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v2_script_list_t* child = cardano_auxiliary_data_get_plutus_v2_scripts(source);
    result                                 = cardano_auxiliary_data_set_plutus_v2_scripts(*output, child);
    cardano_plutus_v2_script_list_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v3_script_list_t* child = cardano_auxiliary_data_get_plutus_v3_scripts(source);
    result                                 = cardano_auxiliary_data_set_plutus_v3_scripts(*output, child);
    cardano_plutus_v3_script_list_unref(&child);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_plutus_v4_script_list_t* child = cardano_auxiliary_data_get_plutus_v4_scripts(source);
    result                                 = cardano_auxiliary_data_set_plutus_v4_scripts(*output, child);
    cardano_plutus_v4_script_list_unref(&child);
  }
  return result;
}

/* kinds: 0 key, 1 bootstrap, 2 redeemer, 3 witness map, 4 auxiliary data.
 * Invalid input returns zero and releases all partial parser state. */
int
cometa_test_transaction_witnesses_agree(unsigned int kind, const unsigned char* input, size_t size)
{
  cardano_cbor_reader_t* reader = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_buffer_t*      buffer = NULL;
  cardano_error_t        result = CARDANO_SUCCESS;
  int                    agrees = 0;
  if (reader == NULL || writer == NULL)
  {
    goto cleanup;
  }
  if (kind == 0)
  {
    cardano_vkey_witness_t* old   = NULL;
    cardano_vkey_witness_t* fresh = NULL;
    result                        = cardano_vkey_witness_from_cbor(reader, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_key(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_vkey_witness_to_cbor(fresh, writer);
    }
    cardano_vkey_witness_unref(&fresh);
    cardano_vkey_witness_unref(&old);
  }
  else if (kind == 1)
  {
    cardano_bootstrap_witness_t* old   = NULL;
    cardano_bootstrap_witness_t* fresh = NULL;
    result                             = cardano_bootstrap_witness_from_cbor(reader, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_bootstrap(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_bootstrap_witness_to_cbor(fresh, writer);
    }
    cardano_bootstrap_witness_unref(&fresh);
    cardano_bootstrap_witness_unref(&old);
  }
  else if (kind == 2)
  {
    cardano_redeemer_t* old   = NULL;
    cardano_redeemer_t* fresh = NULL;
    result                    = cardano_redeemer_from_cbor(reader, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_redeemer(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_redeemer_to_cbor(fresh, writer);
    }
    cardano_redeemer_unref(&fresh);
    cardano_redeemer_unref(&old);
  }
  else if (kind == 3)
  {
    cardano_witness_set_t* old   = NULL;
    cardano_witness_set_t* fresh = NULL;
    result                       = cardano_witness_set_from_cbor(reader, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_witness_set(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_witness_set_to_cbor(fresh, writer);
    }
    cardano_witness_set_unref(&fresh);
    cardano_witness_set_unref(&old);
  }
  else if (kind == 4)
  {
    cardano_auxiliary_data_t* old   = NULL;
    cardano_auxiliary_data_t* fresh = NULL;
    result                          = cardano_auxiliary_data_from_cbor(reader, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_auxiliary_data(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_auxiliary_data_to_cbor(fresh, writer);
    }
    cardano_auxiliary_data_unref(&fresh);
    cardano_auxiliary_data_unref(&old);
  }
  else
  {
    goto cleanup;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &buffer);
  }
  if (result == CARDANO_SUCCESS)
  {
    agrees = cardano_buffer_get_size(buffer) == size && memcmp(cardano_buffer_get_data(buffer), input, size) == 0;
  }
cleanup:
  cardano_buffer_unref(&buffer);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return agrees;
}
