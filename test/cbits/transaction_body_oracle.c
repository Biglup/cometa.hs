/**
 * \file transaction_body_oracle.c
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

/** \brief Rebuild an output through native domain getters and constructors.
 * Every object getter returns a retained reference; setters retain independently.
 * Inline datum identity is deliberately retained, and the output cache is absent.
 */
static cardano_error_t
rebuild_output(cardano_transaction_output_t* source, cardano_transaction_output_t** target)
{
  cardano_address_t* address = cardano_transaction_output_get_address(source);
  cardano_value_t*   value   = cardano_transaction_output_get_value(source);
  cardano_datum_t*   datum   = cardano_transaction_output_get_datum(source);
  cardano_script_t*  script  = cardano_transaction_output_get_script_ref(source);
  cardano_error_t    result  = cardano_transaction_output_new(address, 0U, target);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_output_set_value(*target, value);
  }
  if ((result == CARDANO_SUCCESS) && (datum != NULL))
  {
    result = cardano_transaction_output_set_datum(*target, datum);
  }
  if ((result == CARDANO_SUCCESS) && (script != NULL))
  {
    result = cardano_transaction_output_set_script_ref(*target, script);
  }
  cardano_script_unref(&script);
  cardano_datum_unref(&datum);
  cardano_value_unref(&value);
  cardano_address_unref(&address);
  return result;
}

/** \brief Rebuild a typed body in a new allocation, never serializing its source cache.
 * Object getters transfer retained references, released immediately after setters.
 * Borrowed scalar pointers are used only while the source body remains alive.
 */
static cardano_error_t
rebuild_body(cardano_transaction_body_t* source, cardano_transaction_body_t** target)
{
  cardano_transaction_input_set_t*   inputs  = cardano_transaction_body_get_inputs(source);
  cardano_transaction_output_list_t* outputs = cardano_transaction_body_get_outputs(source);
  cardano_error_t                    result  = cardano_transaction_body_new(inputs, outputs, cardano_transaction_body_get_fee(source), NULL, target);
  cardano_transaction_output_list_unref(&outputs);
  cardano_transaction_input_set_unref(&inputs);
  if (result == CARDANO_SUCCESS)
  {
    cardano_certificate_set_t* value = cardano_transaction_body_get_certificates(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_certificates(*target, value);
    }
    cardano_certificate_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_withdrawal_map_t* value = cardano_transaction_body_get_withdrawals(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_withdrawals(*target, value);
    }
    cardano_withdrawal_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_blake2b_hash_t* value = cardano_transaction_body_get_aux_data_hash(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_aux_data_hash(*target, value);
    }
    cardano_blake2b_hash_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_multi_asset_t* value = cardano_transaction_body_get_mint(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_mint(*target, value);
    }
    cardano_multi_asset_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_blake2b_hash_t* value = cardano_transaction_body_get_script_data_hash(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_script_data_hash(*target, value);
    }
    cardano_blake2b_hash_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_guard_set_t* value = cardano_transaction_body_get_guards(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_guards(*target, value);
    }
    cardano_guard_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_transaction_input_set_t* value = cardano_transaction_body_get_reference_inputs(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_reference_inputs(*target, value);
    }
    cardano_transaction_input_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_voting_procedures_t* value = cardano_transaction_body_get_voting_procedures(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_voting_procedures(*target, value);
    }
    cardano_voting_procedures_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_proposal_procedure_set_t* value = cardano_transaction_body_get_proposal_procedures(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_proposal_procedure(*target, value);
    }
    cardano_proposal_procedure_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_required_guards_map_t* value = cardano_transaction_body_get_required_top_level_guards(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_required_top_level_guards(*target, value);
    }
    cardano_required_guards_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_direct_deposit_map_t* value = cardano_transaction_body_get_direct_deposits(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_direct_deposits(*target, value);
    }
    cardano_direct_deposit_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_account_balance_intervals_map_t* value = cardano_transaction_body_get_account_balance_intervals(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_account_balance_intervals(*target, value);
    }
    cardano_account_balance_intervals_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_update_t* value = cardano_transaction_body_get_update(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_update(*target, value);
    }
    cardano_update_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_transaction_input_set_t* value = cardano_transaction_body_get_collateral(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_collateral(*target, value);
    }
    cardano_transaction_input_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_transaction_output_t* value = cardano_transaction_body_get_collateral_return(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_collateral_return(*target, value);
    }
    cardano_transaction_output_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_sub_transaction_set_t* value = cardano_transaction_body_get_sub_transactions(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_sub_transactions(*target, value);
    }
    cardano_sub_transaction_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_account_balance_intervals_map_t* value = cardano_transaction_body_get_starting_account_balance_intervals(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_starting_account_balance_intervals(*target, value);
    }
    cardano_account_balance_intervals_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_transaction_body_get_invalid_after(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_invalid_after(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_transaction_body_get_invalid_before(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_invalid_before(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const cardano_network_id_t* value = cardano_transaction_body_get_network_id(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_network_id(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_transaction_body_get_treasury_value(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_treasury_value(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_transaction_body_get_donation(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_donation(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_transaction_body_get_total_collateral(source);
    if (value != NULL)
    {
      result = cardano_transaction_body_set_total_collateral(*target, value);
    }
  }
  return result;
}

/** \brief Rebuild a separate subtransaction body; no top-level-only fields exist. */
static cardano_error_t
rebuild_sub_body(cardano_sub_transaction_body_t* source, cardano_sub_transaction_body_t** target)
{
  cardano_transaction_input_set_t*   inputs  = cardano_sub_transaction_body_get_inputs(source);
  cardano_transaction_output_list_t* outputs = cardano_sub_transaction_body_get_outputs(source);
  cardano_error_t                    result  = cardano_sub_transaction_body_new(inputs, outputs, NULL, target);
  cardano_transaction_output_list_unref(&outputs);
  cardano_transaction_input_set_unref(&inputs);
  if (result == CARDANO_SUCCESS)
  {
    cardano_certificate_set_t* value = cardano_sub_transaction_body_get_certificates(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_certificates(*target, value);
    }
    cardano_certificate_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_withdrawal_map_t* value = cardano_sub_transaction_body_get_withdrawals(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_withdrawals(*target, value);
    }
    cardano_withdrawal_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_blake2b_hash_t* value = cardano_sub_transaction_body_get_aux_data_hash(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_aux_data_hash(*target, value);
    }
    cardano_blake2b_hash_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_multi_asset_t* value = cardano_sub_transaction_body_get_mint(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_mint(*target, value);
    }
    cardano_multi_asset_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_blake2b_hash_t* value = cardano_sub_transaction_body_get_script_data_hash(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_script_data_hash(*target, value);
    }
    cardano_blake2b_hash_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_guard_set_t* value = cardano_sub_transaction_body_get_guards(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_guards(*target, value);
    }
    cardano_guard_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_transaction_input_set_t* value = cardano_sub_transaction_body_get_reference_inputs(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_reference_inputs(*target, value);
    }
    cardano_transaction_input_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_voting_procedures_t* value = cardano_sub_transaction_body_get_voting_procedures(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_voting_procedures(*target, value);
    }
    cardano_voting_procedures_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_proposal_procedure_set_t* value = cardano_sub_transaction_body_get_proposal_procedures(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_proposal_procedures(*target, value);
    }
    cardano_proposal_procedure_set_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_required_guards_map_t* value = cardano_sub_transaction_body_get_required_top_level_guards(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_required_top_level_guards(*target, value);
    }
    cardano_required_guards_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_direct_deposit_map_t* value = cardano_sub_transaction_body_get_direct_deposits(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_direct_deposits(*target, value);
    }
    cardano_direct_deposit_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    cardano_account_balance_intervals_map_t* value = cardano_sub_transaction_body_get_account_balance_intervals(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_account_balance_intervals(*target, value);
    }
    cardano_account_balance_intervals_map_unref(&value);
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_sub_transaction_body_get_invalid_after(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_invalid_after(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_sub_transaction_body_get_invalid_before(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_invalid_before(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const cardano_network_id_t* value = cardano_sub_transaction_body_get_network_id(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_network_id(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_sub_transaction_body_get_treasury_value(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_treasury_value(*target, value);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    const uint64_t* value = cardano_sub_transaction_body_get_donation(source);
    if (value != NULL)
    {
      result = cardano_sub_transaction_body_set_donation(*target, value);
    }
  }
  return result;
}

/* DEFINITIONS ***************************************************************/

/** \brief Compare Haskell fresh encoding with native reconstruction (0 body,
 * 1 sub-body, 2 output, 3 input). The source and fresh objects are distinct;
 * all owned references are released on success and failure. Return 9001 for
 * encoding disagreement, native status otherwise. No global state is retained.
 */
int
cometa_test_transaction_body_agree(unsigned int kind, const unsigned char* bytes, size_t size)
{
  cardano_cbor_reader_t*          reader         = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_writer_t*          writer         = cardano_cbor_writer_new();
  cardano_transaction_body_t*     source         = NULL;
  cardano_transaction_body_t*     rebuilt        = NULL;
  cardano_sub_transaction_body_t* sub_source     = NULL;
  cardano_sub_transaction_body_t* sub_rebuilt    = NULL;
  cardano_transaction_output_t*   output_source  = NULL;
  cardano_transaction_output_t*   output_rebuilt = NULL;
  cardano_transaction_input_t*    input_source   = NULL;
  cardano_transaction_input_t*    input_rebuilt  = NULL;
  cardano_blake2b_hash_t*         id             = NULL;
  unsigned char*                  encoded        = NULL;
  int                             result         = CARDANO_SUCCESS;
  if ((reader == NULL) || (writer == NULL))
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  switch (kind)
  {
    case 0:
      result = cardano_transaction_body_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_body(source, &rebuilt);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_transaction_body_to_cbor(rebuilt, writer);
      }
      break;
    case 1:
      result = cardano_sub_transaction_body_from_cbor(reader, &sub_source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_sub_body(sub_source, &sub_rebuilt);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_sub_transaction_body_to_cbor(sub_rebuilt, writer);
      }
      break;
    case 2:
      result = cardano_transaction_output_from_cbor(reader, &output_source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_output(output_source, &output_rebuilt);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_transaction_output_to_cbor(output_rebuilt, writer);
      }
      break;
    case 3:
      result = cardano_transaction_input_from_cbor(reader, &input_source);
      if (result == CARDANO_SUCCESS)
      {
        id     = cardano_transaction_input_get_id(input_source);
        result = cardano_transaction_input_new(id, cardano_transaction_input_get_index(input_source), &input_rebuilt);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_transaction_input_to_cbor(input_rebuilt, writer);
      }
      break;
    default:
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      break;
  }
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  if (cardano_cbor_writer_get_encode_size(writer) != size)
  {
    result = 9001;
    goto cleanup;
  }
  encoded = malloc(size);
  if (encoded == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  result = cardano_cbor_writer_encode(writer, encoded, size);
  if ((result == CARDANO_SUCCESS) && (memcmp(encoded, bytes, size) != 0))
  {
    result = 9001;
  }
cleanup:
  free(encoded);
  cardano_blake2b_hash_unref(&id);
  cardano_transaction_input_unref(&input_rebuilt);
  cardano_transaction_input_unref(&input_source);
  cardano_transaction_output_unref(&output_rebuilt);
  cardano_transaction_output_unref(&output_source);
  cardano_sub_transaction_body_unref(&sub_rebuilt);
  cardano_sub_transaction_body_unref(&sub_source);
  cardano_transaction_body_unref(&rebuilt);
  cardano_transaction_body_unref(&source);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return result;
}
