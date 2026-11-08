/**
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

#include "cometa_inspection.h"

/* STATIC FUNCTIONS **********************************************************/

/* Governance actions have concrete native types, not a generic native owner.
 * Peek with an independent reader; parse the chosen complete action with the
 * original reader, borrow it for JSON, and release before returning. */
static cardano_error_t
inspect_action(const unsigned char* input, size_t size, cardano_cbor_reader_t* reader, cardano_json_writer_t* writer)
{
  cardano_cbor_reader_t* probe = cardano_cbor_reader_new(input, size);
  if (probe == NULL)
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  int64_t         count  = 0;
  uint64_t        tag    = 0;
  cardano_error_t result = cardano_cbor_reader_read_start_array(probe, &count);
  if (result == CARDANO_SUCCESS)
    result = cardano_cbor_reader_read_uint(probe, &tag);
  cardano_cbor_reader_unref(&probe);
  if (result != CARDANO_SUCCESS)
    return result;
  switch (tag)
  {
    case 0U:
    {
      cardano_parameter_change_action_t* action = NULL;
      result                                    = cardano_parameter_change_action_from_cbor(reader, &action);
      if (result == CARDANO_SUCCESS)
        result = cardano_parameter_change_action_to_cip116_json(action, writer);
      cardano_parameter_change_action_unref(&action);
      return result;
    }
    case 1U:
    {
      cardano_hard_fork_initiation_action_t* action = NULL;
      result                                        = cardano_hard_fork_initiation_action_from_cbor(reader, &action);
      if (result == CARDANO_SUCCESS)
        result = cardano_hard_fork_initiation_action_to_cip116_json(action, writer);
      cardano_hard_fork_initiation_action_unref(&action);
      return result;
    }
    case 2U:
    {
      cardano_treasury_withdrawals_action_t* action = NULL;
      result                                        = cardano_treasury_withdrawals_action_from_cbor(reader, &action);
      if (result == CARDANO_SUCCESS)
        result = cardano_treasury_withdrawals_action_to_cip116_json(action, writer);
      cardano_treasury_withdrawals_action_unref(&action);
      return result;
    }
    case 3U:
    {
      cardano_no_confidence_action_t* action = NULL;
      result                                 = cardano_no_confidence_action_from_cbor(reader, &action);
      if (result == CARDANO_SUCCESS)
        result = cardano_no_confidence_action_to_cip116_json(action, writer);
      cardano_no_confidence_action_unref(&action);
      return result;
    }
    case 4U:
    {
      cardano_update_committee_action_t* action = NULL;
      result                                    = cardano_update_committee_action_from_cbor(reader, &action);
      if (result == CARDANO_SUCCESS)
        result = cardano_update_committee_action_to_cip116_json(action, writer);
      cardano_update_committee_action_unref(&action);
      return result;
    }
    case 5U:
    {
      cardano_new_constitution_action_t* action = NULL;
      result                                    = cardano_new_constitution_action_from_cbor(reader, &action);
      if (result == CARDANO_SUCCESS)
        result = cardano_new_constitution_action_to_cip116_json(action, writer);
      cardano_new_constitution_action_unref(&action);
      return result;
    }
    case 6U:
    {
      cardano_info_action_t* action = NULL;
      result                        = cardano_info_action_from_cbor(reader, &action);
      if (result == CARDANO_SUCCESS)
        result = cardano_info_action_to_cip116_json(action, writer);
      cardano_info_action_unref(&action);
      return result;
    }
    default:
      return CARDANO_ERROR_INVALID_ARGUMENT;
  }
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_inspection_compute(unsigned int operation, const unsigned char* input, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }
  *output = NULL;
  if (operation > 46U)
  {
    return CARDANO_ERROR_INVALID_ARGUMENT;
  }
  if (input == NULL && size != 0U)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  cardano_cbor_reader_t*                   reader                            = cardano_cbor_reader_new(input, size);
  cardano_json_writer_t*                   writer                            = cardano_json_writer_new(CARDANO_JSON_FORMAT_COMPACT);
  cardano_transaction_t*                   transaction                       = NULL;
  cardano_sub_transaction_t*               sub                               = NULL;
  cardano_transaction_body_t*              body                              = NULL;
  cardano_sub_transaction_body_t*          sub_body                          = NULL;
  cardano_value_t*                         value                             = NULL;
  cardano_script_t*                        script                            = NULL;
  cardano_credential_t*                    credential                        = NULL;
  cardano_certificate_t*                   certificate                       = NULL;
  cardano_proposal_procedure_t*            proposal                          = NULL;
  cardano_pool_params_t*                   pool                              = NULL;
  cardano_protocol_param_update_t*         update                            = NULL;
  cardano_plutus_data_t*                   data                              = NULL;
  cardano_transaction_output_t*            tx_output                         = NULL;
  cardano_witness_set_t*                   witnesses                         = NULL;
  cardano_utxo_t*                          utxo                              = NULL;
  cardano_drep_t*                          drep                              = NULL;
  cardano_governance_action_id_t*          action_id                         = NULL;
  cardano_anchor_t*                        anchor                            = NULL;
  cardano_voting_procedures_t*             votes                             = NULL;
  cardano_metadatum_t*                     metadatum                         = NULL;
  cardano_transaction_metadata_t*          metadata                          = NULL;
  cardano_auxiliary_data_t*                auxiliary                         = NULL;
  cardano_transaction_input_t*             tx_input                          = NULL;
  cardano_datum_t*                         datum                             = NULL;
  cardano_redeemer_t*                      redeemer                          = NULL;
  cardano_ex_units_t*                      inspection_ex_units               = NULL;
  cardano_protocol_version_t*              inspection_protocol_version       = NULL;
  cardano_unit_interval_t*                 inspection_unit_interval          = NULL;
  cardano_relay_t*                         inspection_relay                  = NULL;
  cardano_pool_metadata_t*                 inspection_pool_metadata          = NULL;
  cardano_constitution_t*                  inspection_constitution           = NULL;
  cardano_voter_t*                         inspection_voter                  = NULL;
  cardano_voting_procedure_t*              inspection_voting_procedure       = NULL;
  cardano_vkey_witness_t*                  inspection_verification_witness   = NULL;
  cardano_bootstrap_witness_t*             inspection_bootstrap_witness      = NULL;
  cardano_cost_model_t*                    inspection_cost_model             = NULL;
  cardano_costmdls_t*                      inspection_cost_models            = NULL;
  cardano_ex_unit_prices_t*                inspection_ex_unit_prices         = NULL;
  cardano_pool_voting_thresholds_t*        inspection_pool_voting_thresholds = NULL;
  cardano_drep_voting_thresholds_t*        inspection_drep_voting_thresholds = NULL;
  cardano_proposed_param_updates_t*        inspection_proposed_updates       = NULL;
  cardano_update_t*                        inspection_update_proposal        = NULL;
  cardano_account_balance_interval_t*      inspection_balance_interval       = NULL;
  cardano_account_balance_intervals_map_t* inspection_balance_intervals      = NULL;
  cardano_direct_deposit_map_t*            inspection_direct_deposits        = NULL;
  cardano_required_guards_map_t*           inspection_required_guards        = NULL;
  size_t                                   remaining                         = 0U;
  cardano_error_t                          result                            = reader == NULL || writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : CARDANO_SUCCESS;

  if (result == CARDANO_SUCCESS)
  {
    switch (operation)
    {
      case 0U:
        result = cardano_transaction_from_cbor(reader, &transaction);
        break;
      case 1U:
        result = cardano_sub_transaction_from_cbor(reader, &sub);
        break;
      case 2U:
        result = cardano_transaction_body_from_cbor(reader, &body);
        break;
      case 3U:
        result = cardano_sub_transaction_body_from_cbor(reader, &sub_body);
        break;
      case 4U:
        result = cardano_value_from_cbor(reader, &value);
        break;
      case 5U:
        result = cardano_script_from_cbor(reader, &script);
        break;
      case 6U:
        result = cardano_credential_from_cbor(reader, &credential);
        break;
      case 7U:
        result = cardano_certificate_from_cbor(reader, &certificate);
        break;
      case 8U:
        result = cardano_proposal_procedure_from_cbor(reader, &proposal);
        break;
      case 9U:
      {
        int64_t count = 0;
        result        = cardano_cbor_reader_read_start_array(reader, &count);
        if (result == CARDANO_SUCCESS && count != 9 && count != 10 && count != -1)
          result = CARDANO_ERROR_DECODING;
        if (result == CARDANO_SUCCESS)
          result = cardano_pool_params_from_cbor(reader, &pool);
        if (result == CARDANO_SUCCESS)
          result = cardano_cbor_reader_read_end_array(reader);
        break;
      }
      case 10U:
        result = cardano_protocol_param_update_from_cbor(reader, &update);
        break;
      case 11U:
        result = cardano_plutus_data_from_cbor(reader, &data);
        break;
      case 12U:
        result = cardano_transaction_output_from_cbor(reader, &tx_output);
        break;
      case 13U:
        result = cardano_witness_set_from_cbor(reader, &witnesses);
        break;
      case 14U:
        result = cardano_utxo_from_cbor(reader, &utxo);
        break;
      case 15U:
        result = cardano_drep_from_cbor(reader, &drep);
        break;
      case 16U:
        result = cardano_governance_action_id_from_cbor(reader, &action_id);
        break;
      case 17U:
        result = cardano_anchor_from_cbor(reader, &anchor);
        break;
      case 18U:
        result = cardano_voting_procedures_from_cbor(reader, &votes);
        break;
      case 19U:
        result = inspect_action(input, size, reader, writer);
        break;
      case 20U:
        result = cardano_metadatum_from_cbor(reader, &metadatum);
        break;
      case 21U:
        result = cardano_transaction_metadata_from_cbor(reader, &metadata);
        break;
      case 22U:
        result = cardano_auxiliary_data_from_cbor(reader, &auxiliary);
        break;
      case 23U:
        result = cardano_transaction_input_from_cbor(reader, &tx_input);
        break;
      case 24U:
        result = cardano_datum_from_cbor(reader, &datum);
        break;
      case 25U:
        result = cardano_redeemer_from_cbor(reader, &redeemer);
        break;
      case 26U:
        result = cardano_ex_units_from_cbor(reader, &inspection_ex_units);
        break;
      case 27U:
        result = cardano_protocol_version_from_cbor(reader, &inspection_protocol_version);
        break;
      case 28U:
        result = cardano_unit_interval_from_cbor(reader, &inspection_unit_interval);
        break;
      case 29U:
        result = cardano_relay_from_cbor(reader, &inspection_relay);
        break;
      case 30U:
        result = cardano_pool_metadata_from_cbor(reader, &inspection_pool_metadata);
        break;
      case 31U:
        result = cardano_constitution_from_cbor(reader, &inspection_constitution);
        break;
      case 32U:
        result = cardano_voter_from_cbor(reader, &inspection_voter);
        break;
      case 33U:
        result = cardano_voting_procedure_from_cbor(reader, &inspection_voting_procedure);
        break;
      case 34U:
        result = cardano_vkey_witness_from_cbor(reader, &inspection_verification_witness);
        break;
      case 35U:
        result = cardano_bootstrap_witness_from_cbor(reader, &inspection_bootstrap_witness);
        break;
      case 36U:
      {
        int64_t count = 0;
        result        = cardano_cbor_reader_read_start_array(reader, &count);
        if (result == CARDANO_SUCCESS && count != 2 && count != -1)
          result = CARDANO_ERROR_DECODING;
        if (result == CARDANO_SUCCESS)
          result = cardano_cost_model_from_cbor(reader, &inspection_cost_model);
        if (result == CARDANO_SUCCESS)
          result = cardano_cbor_reader_read_end_array(reader);
        break;
      }
      case 37U:
        result = cardano_costmdls_from_cbor(reader, &inspection_cost_models);
        break;
      case 38U:
        result = cardano_ex_unit_prices_from_cbor(reader, &inspection_ex_unit_prices);
        break;
      case 39U:
        result = cardano_pool_voting_thresholds_from_cbor(reader, &inspection_pool_voting_thresholds);
        break;
      case 40U:
        result = cardano_drep_voting_thresholds_from_cbor(reader, &inspection_drep_voting_thresholds);
        break;
      case 41U:
        result = cardano_proposed_param_updates_from_cbor(reader, &inspection_proposed_updates);
        break;
      case 42U:
        result = cardano_update_from_cbor(reader, &inspection_update_proposal);
        break;
      case 43U:
        result = cardano_account_balance_interval_from_cbor(reader, &inspection_balance_interval);
        break;
      case 44U:
        result = cardano_account_balance_intervals_map_from_cbor(reader, &inspection_balance_intervals);
        break;
      case 45U:
        result = cardano_direct_deposit_map_from_cbor(reader, &inspection_direct_deposits);
        break;
      case 46U:
        result = cardano_required_guards_map_from_cbor(reader, &inspection_required_guards);
        break;
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
    if (result == CARDANO_SUCCESS && remaining != 0U)
    {
      result = CARDANO_ERROR_DECODING;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    switch (operation)
    {
      case 0U:
        result = cardano_transaction_to_cip116_json(transaction, writer);
        break;
      case 1U:
        result = cardano_sub_transaction_to_cip116_json(sub, writer);
        break;
      case 2U:
        result = cardano_transaction_body_to_cip116_json(body, writer);
        break;
      case 3U:
        result = cardano_sub_transaction_body_to_cip116_json(sub_body, writer);
        break;
      case 4U:
        result = cardano_value_to_cip116_json(value, writer);
        break;
      case 5U:
        result = cardano_script_to_cip116_json(script, writer);
        break;
      case 6U:
        result = cardano_credential_to_cip116_json(credential, writer);
        break;
      case 7U:
        result = cardano_certificate_to_cip116_json(certificate, writer);
        break;
      case 8U:
        result = cardano_proposal_procedure_to_cip116_json(proposal, writer);
        break;
      case 9U:
        result = cardano_pool_params_to_cip116_json(pool, writer);
        break;
      case 10U:
        result = cardano_protocol_param_update_to_cip116_json(update, writer);
        break;
      case 11U:
        result = cardano_plutus_data_to_cip116_json(data, writer);
        break;
      case 12U:
        result = cardano_transaction_output_to_cip116_json(tx_output, writer);
        break;
      case 13U:
        result = cardano_witness_set_to_cip116_json(witnesses, writer);
        break;
      case 14U:
        result = cardano_utxo_to_cip116_json(utxo, writer);
        break;
      case 15U:
        result = cardano_drep_to_cip116_json(drep, writer);
        break;
      case 16U:
        result = cardano_governance_action_id_to_cip116_json(action_id, writer);
        break;
      case 17U:
        result = cardano_anchor_to_cip116_json(anchor, writer);
        break;
      case 18U:
        result = cardano_voting_procedures_to_cip116_json(votes, writer);
        break;
      case 19U:
        break; /* Action inspection already wrote its concrete variant. */
      case 20U:
        result = cardano_metadatum_to_cip116_json(metadatum, writer);
        break;
      case 21U:
        result = cardano_transaction_metadata_to_cip116_json(metadata, writer);
        break;
      case 22U:
        result = cardano_auxiliary_data_to_cip116_json(auxiliary, writer);
        break;
      case 23U:
        result = cardano_transaction_input_to_cip116_json(tx_input, writer);
        break;
      case 24U:
        result = cardano_datum_to_cip116_json(datum, writer);
        break;
      case 25U:
        result = cardano_redeemer_to_cip116_json(redeemer, writer);
        break;
      case 26U:
        result = cardano_ex_units_to_cip116_json(inspection_ex_units, writer);
        break;
      case 27U:
        result = cardano_protocol_version_to_cip116_json(inspection_protocol_version, writer);
        break;
      case 28U:
        result = cardano_unit_interval_to_cip116_json(inspection_unit_interval, writer);
        break;
      case 29U:
        result = cardano_relay_to_cip116_json(inspection_relay, writer);
        break;
      case 30U:
        result = cardano_pool_metadata_to_cip116_json(inspection_pool_metadata, writer);
        break;
      case 31U:
        result = cardano_constitution_to_cip116_json(inspection_constitution, writer);
        break;
      case 32U:
        result = cardano_voter_to_cip116_json(inspection_voter, writer);
        break;
      case 33U:
        result = cardano_voting_procedure_to_cip116_json(inspection_voting_procedure, writer);
        break;
      case 34U:
        result = cardano_vkey_witness_to_cip116_json(inspection_verification_witness, writer);
        break;
      case 35U:
        result = cardano_bootstrap_witness_to_cip116_json(inspection_bootstrap_witness, writer);
        break;
      case 36U:
        result = cardano_cost_model_to_cip116_json(inspection_cost_model, writer);
        break;
      case 37U:
        result = cardano_costmdls_to_cip116_json(inspection_cost_models, writer);
        break;
      case 38U:
        result = cardano_ex_unit_prices_to_cip116_json(inspection_ex_unit_prices, writer);
        break;
      case 39U:
        result = cardano_pool_voting_thresholds_to_cip116_json(inspection_pool_voting_thresholds, writer);
        break;
      case 40U:
        result = cardano_drep_voting_thresholds_to_cip116_json(inspection_drep_voting_thresholds, writer);
        break;
      case 41U:
        result = cardano_proposed_param_updates_to_cip116_json(inspection_proposed_updates, writer);
        break;
      case 42U:
        result = cardano_update_to_cip116_json(inspection_update_proposal, writer);
        break;
      case 43U:
        result = cardano_account_balance_interval_to_cip116_json(inspection_balance_interval, writer);
        break;
      case 44U:
        result = cardano_account_balance_intervals_map_to_cip116_json(inspection_balance_intervals, writer);
        break;
      case 45U:
        result = cardano_direct_deposit_map_to_cip116_json(inspection_direct_deposits, writer);
        break;
      case 46U:
        result = cardano_required_guards_map_to_cip116_json(inspection_required_guards, writer);
        break;
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    /* Native JSON buffers contain their exact length, without a trailing NUL. */
    result = cardano_json_writer_encode_in_buffer(writer, output);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_buffer_unref(output);
    *output = NULL;
  }
  cardano_ex_units_unref(&inspection_ex_units);
  cardano_protocol_version_unref(&inspection_protocol_version);
  cardano_unit_interval_unref(&inspection_unit_interval);
  cardano_relay_unref(&inspection_relay);
  cardano_pool_metadata_unref(&inspection_pool_metadata);
  cardano_constitution_unref(&inspection_constitution);
  cardano_voter_unref(&inspection_voter);
  cardano_voting_procedure_unref(&inspection_voting_procedure);
  cardano_vkey_witness_unref(&inspection_verification_witness);
  cardano_bootstrap_witness_unref(&inspection_bootstrap_witness);
  cardano_cost_model_unref(&inspection_cost_model);
  cardano_costmdls_unref(&inspection_cost_models);
  cardano_ex_unit_prices_unref(&inspection_ex_unit_prices);
  cardano_pool_voting_thresholds_unref(&inspection_pool_voting_thresholds);
  cardano_drep_voting_thresholds_unref(&inspection_drep_voting_thresholds);
  cardano_proposed_param_updates_unref(&inspection_proposed_updates);
  cardano_update_unref(&inspection_update_proposal);
  cardano_account_balance_interval_unref(&inspection_balance_interval);
  cardano_account_balance_intervals_map_unref(&inspection_balance_intervals);
  cardano_direct_deposit_map_unref(&inspection_direct_deposits);
  cardano_required_guards_map_unref(&inspection_required_guards);
  cardano_redeemer_unref(&redeemer);
  cardano_datum_unref(&datum);
  cardano_transaction_input_unref(&tx_input);
  cardano_auxiliary_data_unref(&auxiliary);
  cardano_transaction_metadata_unref(&metadata);
  cardano_metadatum_unref(&metadatum);
  cardano_voting_procedures_unref(&votes);
  cardano_anchor_unref(&anchor);
  cardano_governance_action_id_unref(&action_id);
  cardano_drep_unref(&drep);
  cardano_utxo_unref(&utxo);
  cardano_witness_set_unref(&witnesses);
  cardano_transaction_output_unref(&tx_output);
  cardano_plutus_data_unref(&data);
  cardano_protocol_param_update_unref(&update);
  cardano_pool_params_unref(&pool);
  cardano_proposal_procedure_unref(&proposal);
  cardano_certificate_unref(&certificate);
  cardano_credential_unref(&credential);
  cardano_script_unref(&script);
  cardano_value_unref(&value);
  cardano_sub_transaction_body_unref(&sub_body);
  cardano_transaction_body_unref(&body);
  cardano_sub_transaction_unref(&sub);
  cardano_transaction_unref(&transaction);
  cardano_json_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
