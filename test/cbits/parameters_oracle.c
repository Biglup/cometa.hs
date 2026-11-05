/**
 * \file script_oracle.c
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

#include <cardano/cbor/cbor_reader.h>
#include <cardano/cbor/cbor_writer.h>
#include <cardano/protocol_params/protocol_param_update.h>
#include <cardano/protocol_params/protocol_parameters.h>
#include <string.h>

/* STRUCTURES ****************************************************************/

/** \brief Typed scalar-field operations. No function-pointer casts are used. */
typedef struct uint_field_t
{
    cardano_error_t (*read_update)(const cardano_protocol_param_update_t*, uint64_t*);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, uint64_t);
    uint64_t (*read_full)(const cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, const uint64_t*);
} uint_field_t;

/** \brief Typed buffer accessors; each getter output owns one reference. */
typedef struct buffer_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_buffer_t**);
    cardano_error_t   (*write_full)(cardano_protocol_parameters_t*, cardano_buffer_t*);
    cardano_buffer_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_buffer_t*);
} buffer_field_t;

/** \brief Typed costmdls accessors; each getter output owns one reference. */
typedef struct costmdls_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_costmdls_t**);
    cardano_error_t     (*write_full)(cardano_protocol_parameters_t*, cardano_costmdls_t*);
    cardano_costmdls_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_costmdls_t*);
} costmdls_field_t;

/** \brief Typed drep_voting_thresholds accessors; each getter output owns one reference. */
typedef struct drep_voting_thresholds_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_drep_voting_thresholds_t**);
    cardano_error_t                   (*write_full)(cardano_protocol_parameters_t*, cardano_drep_voting_thresholds_t*);
    cardano_drep_voting_thresholds_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_drep_voting_thresholds_t*);
} drep_voting_thresholds_field_t;

/** \brief Typed ex_unit_prices accessors; each getter output owns one reference. */
typedef struct ex_unit_prices_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_ex_unit_prices_t**);
    cardano_error_t           (*write_full)(cardano_protocol_parameters_t*, cardano_ex_unit_prices_t*);
    cardano_ex_unit_prices_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_ex_unit_prices_t*);
} ex_unit_prices_field_t;

/** \brief Typed ex_units accessors; each getter output owns one reference. */
typedef struct ex_units_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_ex_units_t**);
    cardano_error_t     (*write_full)(cardano_protocol_parameters_t*, cardano_ex_units_t*);
    cardano_ex_units_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_ex_units_t*);
} ex_units_field_t;

/** \brief Typed pool_voting_thresholds accessors; each getter output owns one reference. */
typedef struct pool_voting_thresholds_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_pool_voting_thresholds_t**);
    cardano_error_t                   (*write_full)(cardano_protocol_parameters_t*, cardano_pool_voting_thresholds_t*);
    cardano_pool_voting_thresholds_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_pool_voting_thresholds_t*);
} pool_voting_thresholds_field_t;

/** \brief Typed protocol_version accessors; each getter output owns one reference. */
typedef struct protocol_version_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_protocol_version_t**);
    cardano_error_t             (*write_full)(cardano_protocol_parameters_t*, cardano_protocol_version_t*);
    cardano_protocol_version_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_protocol_version_t*);
} protocol_version_field_t;

/** \brief Typed unit_interval accessors; each getter output owns one reference. */
typedef struct unit_interval_field_t
{
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_unit_interval_t**);
    cardano_error_t          (*write_full)(cardano_protocol_parameters_t*, cardano_unit_interval_t*);
    cardano_unit_interval_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_unit_interval_t*);
} unit_interval_field_t;

/* STATIC FUNCTIONS **********************************************************/

/** \brief Copy one present scalar through full setters/getters into a fresh update. */
static cardano_error_t
copy_uint(const uint_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  uint64_t        value  = 0U;
  cardano_error_t result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, &value);
  }
  return result;
}

/** \brief Copy one present buffer field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_buffer(const buffer_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_buffer_t* value  = NULL;
  cardano_error_t   result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_buffer_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_buffer_unref(&value);
  return result;
}

/** \brief Copy one present costmdls field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_costmdls(const costmdls_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_costmdls_t* value  = NULL;
  cardano_error_t     result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_costmdls_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_costmdls_unref(&value);
  return result;
}

/** \brief Copy one present drep_voting_thresholds field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_drep_voting_thresholds(const drep_voting_thresholds_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_drep_voting_thresholds_t* value  = NULL;
  cardano_error_t                   result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_drep_voting_thresholds_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_drep_voting_thresholds_unref(&value);
  return result;
}

/** \brief Copy one present ex_unit_prices field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_ex_unit_prices(const ex_unit_prices_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_ex_unit_prices_t* value  = NULL;
  cardano_error_t           result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_ex_unit_prices_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_ex_unit_prices_unref(&value);
  return result;
}

/** \brief Copy one present ex_units field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_ex_units(const ex_units_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_ex_units_t* value  = NULL;
  cardano_error_t     result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_ex_units_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_ex_units_unref(&value);
  return result;
}

/** \brief Copy one present pool_voting_thresholds field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_pool_voting_thresholds(const pool_voting_thresholds_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_pool_voting_thresholds_t* value  = NULL;
  cardano_error_t                   result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_pool_voting_thresholds_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_pool_voting_thresholds_unref(&value);
  return result;
}

/** \brief Copy one present protocol_version field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_protocol_version(const protocol_version_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_protocol_version_t* value  = NULL;
  cardano_error_t             result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_protocol_version_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_protocol_version_unref(&value);
  return result;
}

/** \brief Copy one present unit_interval field through both typed representations.
 * Both retained getter obligations are released once, including failed setters.
 * The released local is nulled before another getter can acquire a reference.
 */
static cardano_error_t
copy_unit_interval(const unit_interval_field_t* field, cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_unit_interval_t* value  = NULL;
  cardano_error_t          result = field->read_update(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = field->write_full(full, value);
  }
  cardano_unit_interval_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value  = field->read_full(full);
    result = field->write_update(fresh, value);
  }
  cardano_unit_interval_unref(&value);
  return result;
}

/** \brief Preserve absent, bounded and unbounded maximum pledge leverage.
 * Getter outputs retain one reference; full parameters and fresh updates retain
 * independent references. No acquired reference survives this function.
 */
static cardano_error_t
copy_leverage(cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  cardano_unit_interval_t* value  = NULL;
  cardano_error_t          result = cardano_protocol_param_update_get_max_pledge_leverage(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_protocol_parameters_set_max_pledge_leverage(full, value);
  }
  cardano_unit_interval_unref(&value);
  value = NULL;

  if (result == CARDANO_SUCCESS)
  {
    value = cardano_protocol_parameters_get_max_pledge_leverage(full);
    if (value == NULL)
    {
      result = cardano_protocol_param_update_set_max_pledge_leverage_unbounded(fresh);
    }
    else
    {
      result = cardano_protocol_param_update_set_max_pledge_leverage(fresh, value);
    }
  }
  cardano_unit_interval_unref(&value);
  return result;
}

/** \brief Preserve absent, explicit-null and numeric Peras bootstrap rounds.
 * The full getter borrows a scalar pointer only until its owner is released.
 */
static cardano_error_t
copy_bootstrap_round(cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  if (!cardano_protocol_param_update_has_peras_bootstrap_round(source))
  {
    return CARDANO_SUCCESS;
  }
  if (cardano_protocol_param_update_is_peras_bootstrap_round_null(source))
  {
    cardano_error_t result = cardano_protocol_parameters_set_peras_bootstrap_round(full, NULL);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_protocol_param_update_set_peras_bootstrap_round_null(fresh);
    }
    return result;
  }
  uint64_t        value  = 0U;
  cardano_error_t result = cardano_protocol_param_update_get_peras_bootstrap_round(source, &value);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_protocol_parameters_set_peras_bootstrap_round(full, &value);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_protocol_param_update_set_peras_bootstrap_round(fresh, cardano_protocol_parameters_get_peras_bootstrap_round(full));
  }
  return result;
}

/**
 * \brief Check the signed full-setter boundary before narrowing max value size.
 * The sparse update and full getter expose uint64_t, but the pinned full setter
 * takes int64_t. Values above INT64_MAX therefore traverse only the sparse typed
 * getter/setter. This does not treat implementation-defined narrowing as support.
 */
static cardano_error_t
copy_max_value_size(cardano_protocol_param_update_t* source, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* fresh)
{
  uint64_t        value  = 0U;
  cardano_error_t result = cardano_protocol_param_update_get_max_value_size(source, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if ((result == CARDANO_SUCCESS) && (value <= INT64_MAX))
  {
    result = cardano_protocol_parameters_set_max_value_size(full, (int64_t)value);
    if (result == CARDANO_SUCCESS)
    {
      value = cardano_protocol_parameters_get_max_value_size(full);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_protocol_param_update_set_max_value_size(fresh, &value);
  }
  return result;
}

/* STATIC CONSTANTS **********************************************************/

static const uint_field_t uint_fields[] = {
  { cardano_protocol_param_update_get_min_fee_a, cardano_protocol_parameters_set_min_fee_a, cardano_protocol_parameters_get_min_fee_a, cardano_protocol_param_update_set_min_fee_a },
  { cardano_protocol_param_update_get_min_fee_b, cardano_protocol_parameters_set_min_fee_b, cardano_protocol_parameters_get_min_fee_b, cardano_protocol_param_update_set_min_fee_b },
  { cardano_protocol_param_update_get_max_block_body_size, cardano_protocol_parameters_set_max_block_body_size, cardano_protocol_parameters_get_max_block_body_size, cardano_protocol_param_update_set_max_block_body_size },
  { cardano_protocol_param_update_get_max_tx_size, cardano_protocol_parameters_set_max_tx_size, cardano_protocol_parameters_get_max_tx_size, cardano_protocol_param_update_set_max_tx_size },
  { cardano_protocol_param_update_get_max_block_header_size, cardano_protocol_parameters_set_max_block_header_size, cardano_protocol_parameters_get_max_block_header_size, cardano_protocol_param_update_set_max_block_header_size },
  { cardano_protocol_param_update_get_key_deposit, cardano_protocol_parameters_set_key_deposit, cardano_protocol_parameters_get_key_deposit, cardano_protocol_param_update_set_key_deposit },
  { cardano_protocol_param_update_get_pool_deposit, cardano_protocol_parameters_set_pool_deposit, cardano_protocol_parameters_get_pool_deposit, cardano_protocol_param_update_set_pool_deposit },
  { cardano_protocol_param_update_get_max_epoch, cardano_protocol_parameters_set_max_epoch, cardano_protocol_parameters_get_max_epoch, cardano_protocol_param_update_set_max_epoch },
  { cardano_protocol_param_update_get_n_opt, cardano_protocol_parameters_set_n_opt, cardano_protocol_parameters_get_n_opt, cardano_protocol_param_update_set_n_opt },
  { cardano_protocol_param_update_get_min_pool_cost, cardano_protocol_parameters_set_min_pool_cost, cardano_protocol_parameters_get_min_pool_cost, cardano_protocol_param_update_set_min_pool_cost },
  { cardano_protocol_param_update_get_ada_per_utxo_byte, cardano_protocol_parameters_set_ada_per_utxo_byte, cardano_protocol_parameters_get_ada_per_utxo_byte, cardano_protocol_param_update_set_ada_per_utxo_byte },
  { cardano_protocol_param_update_get_collateral_percentage, cardano_protocol_parameters_set_collateral_percentage, cardano_protocol_parameters_get_collateral_percentage, cardano_protocol_param_update_set_collateral_percentage },
  { cardano_protocol_param_update_get_max_collateral_inputs, cardano_protocol_parameters_set_max_collateral_inputs, cardano_protocol_parameters_get_max_collateral_inputs, cardano_protocol_param_update_set_max_collateral_inputs },
  { cardano_protocol_param_update_get_min_committee_size, cardano_protocol_parameters_set_min_committee_size, cardano_protocol_parameters_get_min_committee_size, cardano_protocol_param_update_set_min_committee_size },
  { cardano_protocol_param_update_get_committee_term_limit, cardano_protocol_parameters_set_committee_term_limit, cardano_protocol_parameters_get_committee_term_limit, cardano_protocol_param_update_set_committee_term_limit },
  { cardano_protocol_param_update_get_governance_action_validity_period, cardano_protocol_parameters_set_governance_action_validity_period, cardano_protocol_parameters_get_governance_action_validity_period, cardano_protocol_param_update_set_governance_action_validity_period },
  { cardano_protocol_param_update_get_governance_action_deposit, cardano_protocol_parameters_set_governance_action_deposit, cardano_protocol_parameters_get_governance_action_deposit, cardano_protocol_param_update_set_governance_action_deposit },
  { cardano_protocol_param_update_get_drep_deposit, cardano_protocol_parameters_set_drep_deposit, cardano_protocol_parameters_get_drep_deposit, cardano_protocol_param_update_set_drep_deposit },
  { cardano_protocol_param_update_get_drep_inactivity_period, cardano_protocol_parameters_set_drep_inactivity_period, cardano_protocol_parameters_get_drep_inactivity_period, cardano_protocol_param_update_set_drep_inactivity_period },
  { cardano_protocol_param_update_get_max_ref_script_size_per_block, cardano_protocol_parameters_set_max_ref_script_size_per_block, cardano_protocol_parameters_get_max_ref_script_size_per_block, cardano_protocol_param_update_set_max_ref_script_size_per_block },
  { cardano_protocol_param_update_get_max_ref_script_size_per_tx, cardano_protocol_parameters_set_max_ref_script_size_per_tx, cardano_protocol_parameters_get_max_ref_script_size_per_tx, cardano_protocol_param_update_set_max_ref_script_size_per_tx },
  { cardano_protocol_param_update_get_ref_script_cost_stride, cardano_protocol_parameters_set_ref_script_cost_stride, cardano_protocol_parameters_get_ref_script_cost_stride, cardano_protocol_param_update_set_ref_script_cost_stride },
  { cardano_protocol_param_update_get_leios_announcement_period_length, cardano_protocol_parameters_set_leios_announcement_period_length, cardano_protocol_parameters_get_leios_announcement_period_length, cardano_protocol_param_update_set_leios_announcement_period_length },
  { cardano_protocol_param_update_get_leios_vote_period_length, cardano_protocol_parameters_set_leios_vote_period_length, cardano_protocol_parameters_get_leios_vote_period_length, cardano_protocol_param_update_set_leios_vote_period_length },
  { cardano_protocol_param_update_get_leios_diffusion_period_length, cardano_protocol_parameters_set_leios_diffusion_period_length, cardano_protocol_parameters_get_leios_diffusion_period_length, cardano_protocol_param_update_set_leios_diffusion_period_length },
  { cardano_protocol_param_update_get_leios_committee_size, cardano_protocol_parameters_set_leios_committee_size, cardano_protocol_parameters_get_leios_committee_size, cardano_protocol_param_update_set_leios_committee_size },
  { cardano_protocol_param_update_get_max_endorser_block_references_size, cardano_protocol_parameters_set_max_endorser_block_references_size, cardano_protocol_parameters_get_max_endorser_block_references_size, cardano_protocol_param_update_set_max_endorser_block_references_size },
  { cardano_protocol_param_update_get_max_endorser_block_txs_size, cardano_protocol_parameters_set_max_endorser_block_txs_size, cardano_protocol_parameters_get_max_endorser_block_txs_size, cardano_protocol_param_update_set_max_endorser_block_txs_size },
  { cardano_protocol_param_update_get_max_ref_script_size_per_endorser_block, cardano_protocol_parameters_set_max_ref_script_size_per_endorser_block, cardano_protocol_parameters_get_max_ref_script_size_per_endorser_block, cardano_protocol_param_update_set_max_ref_script_size_per_endorser_block },
  { cardano_protocol_param_update_get_peras_min_candidate_block_age, cardano_protocol_parameters_set_peras_min_candidate_block_age, cardano_protocol_parameters_get_peras_min_candidate_block_age, cardano_protocol_param_update_set_peras_min_candidate_block_age },
  { cardano_protocol_param_update_get_peras_cert_boost, cardano_protocol_parameters_set_peras_cert_boost, cardano_protocol_parameters_get_peras_cert_boost, cardano_protocol_param_update_set_peras_cert_boost },
  { cardano_protocol_param_update_get_peras_target_committee_size, cardano_protocol_parameters_set_peras_target_committee_size, cardano_protocol_parameters_get_peras_target_committee_size, cardano_protocol_param_update_set_peras_target_committee_size },
  { cardano_protocol_param_update_get_ref_inputs_cost_per_multi_asset_policy, cardano_protocol_parameters_set_ref_inputs_cost_per_multi_asset_policy, cardano_protocol_parameters_get_ref_inputs_cost_per_multi_asset_policy, cardano_protocol_param_update_set_ref_inputs_cost_per_multi_asset_policy },
  { cardano_protocol_param_update_get_ref_inputs_cost_per_datum_byte, cardano_protocol_parameters_set_ref_inputs_cost_per_datum_byte, cardano_protocol_parameters_get_ref_inputs_cost_per_datum_byte, cardano_protocol_param_update_set_ref_inputs_cost_per_datum_byte },
};

static const buffer_field_t buffer_fields[] = {
  { cardano_protocol_param_update_get_extra_entropy, cardano_protocol_parameters_set_extra_entropy, cardano_protocol_parameters_get_extra_entropy, cardano_protocol_param_update_set_extra_entropy },
};

static const costmdls_field_t costmdls_fields[] = {
  { cardano_protocol_param_update_get_cost_models, cardano_protocol_parameters_set_cost_models, cardano_protocol_parameters_get_cost_models, cardano_protocol_param_update_set_cost_models },
};

static const drep_voting_thresholds_field_t drep_voting_thresholds_fields[] = {
  { cardano_protocol_param_update_get_drep_voting_thresholds, cardano_protocol_parameters_set_drep_voting_thresholds, cardano_protocol_parameters_get_drep_voting_thresholds, cardano_protocol_param_update_set_drep_voting_thresholds },
};

static const ex_unit_prices_field_t ex_unit_prices_fields[] = {
  { cardano_protocol_param_update_get_execution_costs, cardano_protocol_parameters_set_execution_costs, cardano_protocol_parameters_get_execution_costs, cardano_protocol_param_update_set_execution_costs },
};

static const ex_units_field_t ex_units_fields[] = {
  { cardano_protocol_param_update_get_max_tx_ex_units, cardano_protocol_parameters_set_max_tx_ex_units, cardano_protocol_parameters_get_max_tx_ex_units, cardano_protocol_param_update_set_max_tx_ex_units },
  { cardano_protocol_param_update_get_max_block_ex_units, cardano_protocol_parameters_set_max_block_ex_units, cardano_protocol_parameters_get_max_block_ex_units, cardano_protocol_param_update_set_max_block_ex_units },
  { cardano_protocol_param_update_get_max_endorser_block_execution_units, cardano_protocol_parameters_set_max_endorser_block_execution_units, cardano_protocol_parameters_get_max_endorser_block_execution_units, cardano_protocol_param_update_set_max_endorser_block_execution_units },
};

static const pool_voting_thresholds_field_t pool_voting_thresholds_fields[] = {
  { cardano_protocol_param_update_get_pool_voting_thresholds, cardano_protocol_parameters_set_pool_voting_thresholds, cardano_protocol_parameters_get_pool_voting_thresholds, cardano_protocol_param_update_set_pool_voting_thresholds },
};

static const protocol_version_field_t protocol_version_fields[] = {
  { cardano_protocol_param_update_get_protocol_version, cardano_protocol_parameters_set_protocol_version, cardano_protocol_parameters_get_protocol_version, cardano_protocol_param_update_set_protocol_version },
};

static const unit_interval_field_t unit_interval_fields[] = {
  { cardano_protocol_param_update_get_pool_pledge_influence, cardano_protocol_parameters_set_pool_pledge_influence, cardano_protocol_parameters_get_pool_pledge_influence, cardano_protocol_param_update_set_pool_pledge_influence },
  { cardano_protocol_param_update_get_expansion_rate, cardano_protocol_parameters_set_expansion_rate, cardano_protocol_parameters_get_expansion_rate, cardano_protocol_param_update_set_expansion_rate },
  { cardano_protocol_param_update_get_treasury_growth_rate, cardano_protocol_parameters_set_treasury_growth_rate, cardano_protocol_parameters_get_treasury_growth_rate, cardano_protocol_param_update_set_treasury_growth_rate },
  { cardano_protocol_param_update_get_d, cardano_protocol_parameters_set_d, cardano_protocol_parameters_get_d, cardano_protocol_param_update_set_d },
  { cardano_protocol_param_update_get_ref_script_cost_per_byte, cardano_protocol_parameters_set_ref_script_cost_per_byte, cardano_protocol_parameters_get_ref_script_cost_per_byte, cardano_protocol_param_update_set_ref_script_cost_per_byte },
  { cardano_protocol_param_update_get_ref_script_cost_multiplier, cardano_protocol_parameters_set_ref_script_cost_multiplier, cardano_protocol_parameters_get_ref_script_cost_multiplier, cardano_protocol_param_update_set_ref_script_cost_multiplier },
  { cardano_protocol_param_update_get_min_pool_margin, cardano_protocol_parameters_set_min_pool_margin, cardano_protocol_parameters_get_min_pool_margin, cardano_protocol_param_update_set_min_pool_margin },
  { cardano_protocol_param_update_get_leios_quorum_stake_threshold, cardano_protocol_parameters_set_leios_quorum_stake_threshold, cardano_protocol_parameters_get_leios_quorum_stake_threshold, cardano_protocol_param_update_set_leios_quorum_stake_threshold },
  { cardano_protocol_param_update_get_peras_healing_factor, cardano_protocol_parameters_set_peras_healing_factor, cardano_protocol_parameters_get_peras_healing_factor, cardano_protocol_param_update_set_peras_healing_factor },
  { cardano_protocol_param_update_get_peras_quorum_threshold_safety_margin, cardano_protocol_parameters_set_peras_quorum_threshold_safety_margin, cardano_protocol_parameters_get_peras_quorum_threshold_safety_margin, cardano_protocol_param_update_set_peras_quorum_threshold_safety_margin },
};

/* DEFINITIONS ***************************************************************/

/** \brief Rebuild all 56 sparse fields through full typed native parameters.
 * Input spans are borrowed until synchronous return. All allocated owners and
 * all getter references are released on success and failure; no owner escapes.
 * The output parent is fresh, so cached input bytes cannot establish agreement.
 */
int
cometa_test_parameters_agreement(const unsigned char* input, size_t input_size, const unsigned char* expected, size_t expected_size)
{
  cardano_cbor_reader_t*           reader  = cardano_cbor_reader_new(input, input_size);
  cardano_cbor_writer_t*           writer  = cardano_cbor_writer_new();
  cardano_protocol_param_update_t* source  = NULL;
  cardano_protocol_param_update_t* fresh   = NULL;
  cardano_protocol_parameters_t*   full    = NULL;
  cardano_buffer_t*                encoded = NULL;
  cardano_error_t                  result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  int                              agrees  = 0;

  if (reader == NULL || writer == NULL)
  {
    goto cleanup;
  }
  result = cardano_protocol_param_update_from_cbor(reader, &source);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  result = cardano_protocol_param_update_new(&fresh);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  result = cardano_protocol_parameters_new(&full);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  for (size_t i = 0U; i < sizeof(uint_fields) / sizeof(uint_fields[0]); ++i)
  {
    result = copy_uint(&uint_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(buffer_fields) / sizeof(buffer_fields[0]); ++i)
  {
    result = copy_buffer(&buffer_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(costmdls_fields) / sizeof(costmdls_fields[0]); ++i)
  {
    result = copy_costmdls(&costmdls_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(drep_voting_thresholds_fields) / sizeof(drep_voting_thresholds_fields[0]); ++i)
  {
    result = copy_drep_voting_thresholds(&drep_voting_thresholds_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(ex_unit_prices_fields) / sizeof(ex_unit_prices_fields[0]); ++i)
  {
    result = copy_ex_unit_prices(&ex_unit_prices_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(ex_units_fields) / sizeof(ex_units_fields[0]); ++i)
  {
    result = copy_ex_units(&ex_units_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(pool_voting_thresholds_fields) / sizeof(pool_voting_thresholds_fields[0]); ++i)
  {
    result = copy_pool_voting_thresholds(&pool_voting_thresholds_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(protocol_version_fields) / sizeof(protocol_version_fields[0]); ++i)
  {
    result = copy_protocol_version(&protocol_version_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  for (size_t i = 0U; i < sizeof(unit_interval_fields) / sizeof(unit_interval_fields[0]); ++i)
  {
    result = copy_unit_interval(&unit_interval_fields[i], source, full, fresh);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  result = copy_max_value_size(source, full, fresh);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  result = copy_leverage(source, full, fresh);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  result = copy_bootstrap_round(source, full, fresh);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  result = cardano_protocol_param_update_to_cbor(fresh, writer);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  }
  if (result == CARDANO_SUCCESS)
  {
    agrees = cardano_buffer_get_size(encoded) == expected_size && memcmp(cardano_buffer_get_data(encoded), expected, expected_size) == 0;
  }

cleanup:
  cardano_buffer_unref(&encoded);
  cardano_protocol_parameters_unref(&full);
  cardano_protocol_param_update_unref(&fresh);
  cardano_protocol_param_update_unref(&source);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return agrees;
}
