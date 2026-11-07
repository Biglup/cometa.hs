/**
 * \file cometa_parameters.c
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

#include "cometa_parameters.h"
#include <cardano/cardano.h>
#include <limits.h>
#include <stdbool.h>

/* STRUCTURES ****************************************************************/

/** \brief Typed scalar-field operations. No function-pointer casts are used. */
typedef struct uint_field_t
{
    bool required;
    cardano_error_t (*read_update)(const cardano_protocol_param_update_t*, uint64_t*);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, uint64_t);
    uint64_t (*read_full)(const cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, const uint64_t*);
} uint_field_t;

/** \brief Typed buffer accessors; each getter output owns one reference. */
typedef struct buffer_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_buffer_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_buffer_t*);
    cardano_buffer_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_buffer_t*);
} buffer_field_t;

/** \brief Typed costmdls accessors; each getter output owns one reference. */
typedef struct costmdls_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_costmdls_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_costmdls_t*);
    cardano_costmdls_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_costmdls_t*);
} costmdls_field_t;

/** \brief Typed drep_voting_thresholds accessors; each getter output owns one reference. */
typedef struct drep_voting_thresholds_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_drep_voting_thresholds_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_drep_voting_thresholds_t*);
    cardano_drep_voting_thresholds_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_drep_voting_thresholds_t*);
} drep_voting_thresholds_field_t;

/** \brief Typed ex_unit_prices accessors; each getter output owns one reference. */
typedef struct ex_unit_prices_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_ex_unit_prices_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_ex_unit_prices_t*);
    cardano_ex_unit_prices_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_ex_unit_prices_t*);
} ex_unit_prices_field_t;

/** \brief Typed ex_units accessors; each getter output owns one reference. */
typedef struct ex_units_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_ex_units_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_ex_units_t*);
    cardano_ex_units_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_ex_units_t*);
} ex_units_field_t;

/** \brief Typed pool_voting_thresholds accessors; each getter output owns one reference. */
typedef struct pool_voting_thresholds_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_pool_voting_thresholds_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_pool_voting_thresholds_t*);
    cardano_pool_voting_thresholds_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_pool_voting_thresholds_t*);
} pool_voting_thresholds_field_t;

/** \brief Typed protocol_version accessors; each getter output owns one reference. */
typedef struct protocol_version_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_protocol_version_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_protocol_version_t*);
    cardano_protocol_version_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_protocol_version_t*);
} protocol_version_field_t;

/** \brief Typed unit_interval accessors; each getter output owns one reference. */
typedef struct unit_interval_field_t
{
    bool required;
    cardano_error_t (*read_update)(cardano_protocol_param_update_t*, cardano_unit_interval_t**);
    cardano_error_t (*write_full)(cardano_protocol_parameters_t*, cardano_unit_interval_t*);
    cardano_unit_interval_t* (*read_full)(cardano_protocol_parameters_t*);
    cardano_error_t (*write_update)(cardano_protocol_param_update_t*, cardano_unit_interval_t*);
} unit_interval_field_t;

/* STATIC FUNCTIONS **********************************************************/

/** \brief Parse one complete snapshot map; no input bytes escape the call. */
static cardano_error_t
read_snapshot(const unsigned char* bytes, size_t size, cardano_protocol_param_update_t** snapshot)
{
  *snapshot                     = NULL;
  cardano_cbor_reader_t* reader = cardano_cbor_reader_new(bytes, size);
  if (reader == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  cardano_error_t result    = cardano_protocol_param_update_from_cbor(reader, snapshot);
  size_t          remaining = 0U;
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
    if ((result == CARDANO_SUCCESS) && (remaining != 0U))
    {
      result = CARDANO_ERROR_INVALID_ARGUMENT;
    }
  }
  cardano_cbor_reader_unref(&reader);
  if (result != CARDANO_SUCCESS)
  {
    cardano_protocol_param_update_unref(snapshot);
  }
  return result;
}

/** \brief Copy scalar values in one direction, preserving source presence.
 * Full scalar getters have no presence bits: exporting consults a supplied
 * availability template when known, otherwise materializes actual scalar values.
 */
static cardano_error_t
transfer_uint(const uint_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  uint64_t        value  = 0U;
  cardano_error_t result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result != CARDANO_SUCCESS)
  {
    return result;
  }
  if (importing)
  {
    if ((field->read_full == cardano_protocol_parameters_get_ref_script_cost_stride) && (value == 0U))
    {
      return CARDANO_ERROR_INVALID_ARGUMENT;
    }
    return field->write_full(full, value);
  }
  value = field->read_full(full);
  /* Zero is an unset/unrepresentable sentinel for the positive-only stride.
     Native storage cannot distinguish unavailable from an invalid explicit zero. */
  if ((shape == NULL) && (field->read_full == cardano_protocol_parameters_get_ref_script_cost_stride) && (value == 0U))
  {
    return CARDANO_SUCCESS;
  }
  return field->write_update(output, &value);
}

/** \brief Transfer a typed buffer field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_buffer(const buffer_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_buffer_t* value  = NULL;
  cardano_error_t   result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_buffer_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_buffer_unref(&value);
  return result;
}

/** \brief Transfer a typed costmdls field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_costmdls(const costmdls_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_costmdls_t* value  = NULL;
  cardano_error_t     result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_costmdls_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_costmdls_unref(&value);
  return result;
}

/** \brief Transfer a typed drep_voting_thresholds field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_drep_voting_thresholds(const drep_voting_thresholds_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_drep_voting_thresholds_t* value  = NULL;
  cardano_error_t                   result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_drep_voting_thresholds_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_drep_voting_thresholds_unref(&value);
  return result;
}

/** \brief Transfer a typed ex_unit_prices field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_ex_unit_prices(const ex_unit_prices_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_ex_unit_prices_t* value  = NULL;
  cardano_error_t           result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_ex_unit_prices_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_ex_unit_prices_unref(&value);
  return result;
}

/** \brief Transfer a typed ex_units field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_ex_units(const ex_units_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_ex_units_t* value  = NULL;
  cardano_error_t     result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_ex_units_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_ex_units_unref(&value);
  return result;
}

/** \brief Transfer a typed pool_voting_thresholds field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_pool_voting_thresholds(const pool_voting_thresholds_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_pool_voting_thresholds_t* value  = NULL;
  cardano_error_t                   result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_pool_voting_thresholds_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_pool_voting_thresholds_unref(&value);
  return result;
}

/** \brief Transfer a typed protocol_version field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_protocol_version(const protocol_version_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_protocol_version_t* value  = NULL;
  cardano_error_t             result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_protocol_version_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_protocol_version_unref(&value);
  return result;
}

/** \brief Transfer a typed unit_interval field. Both getters return retained references.
 * Release the shape's reference before acquiring the full value; failed setters
 * do not consume either reference. NULL is invalid for a declared present field.
 */
static cardano_error_t
transfer_unit_interval(const unit_interval_field_t* field, cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_unit_interval_t* value  = NULL;
  cardano_error_t          result = shape == NULL ? CARDANO_SUCCESS : field->read_update(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return field->required ? CARDANO_ERROR_INVALID_ARGUMENT : CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = field->write_full(full, value);
    }
    else
    {
      cardano_unit_interval_unref(&value);
      value  = NULL;
      value  = field->read_full(full);
      result = value == NULL ? ((shape == NULL && !field->required) ? CARDANO_SUCCESS : CARDANO_ERROR_INVALID_ARGUMENT) : field->write_update(output, value);
    }
  }
  cardano_unit_interval_unref(&value);
  return result;
}

/** \brief Enforce the signed native max-value-size setter boundary without narrowing. */
static cardano_error_t
transfer_max_value_size(cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  uint64_t        value  = 0U;
  cardano_error_t result = shape == NULL ? CARDANO_SUCCESS : cardano_protocol_param_update_get_max_value_size(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result != CARDANO_SUCCESS)
  {
    return result;
  }
  if (importing)
  {
    return value > INT64_MAX ? CARDANO_ERROR_INVALID_ARGUMENT : cardano_protocol_parameters_set_max_value_size(full, (int64_t)value);
  }
  value = cardano_protocol_parameters_get_max_value_size(full);
  return cardano_protocol_param_update_set_max_value_size(output, &value);
}

/** \brief Transfer nullable leverage; NULL here explicitly means unbounded. */
static cardano_error_t
transfer_leverage(cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_unit_interval_t* value  = NULL;
  cardano_error_t          result = shape == NULL ? CARDANO_SUCCESS : cardano_protocol_param_update_get_max_pledge_leverage(shape, &value);
  if (result == CARDANO_ERROR_ELEMENT_NOT_FOUND)
  {
    return CARDANO_SUCCESS;
  }
  if (result == CARDANO_SUCCESS)
  {
    if (importing)
    {
      result = cardano_protocol_parameters_set_max_pledge_leverage(full, value);
    }
    else
    {
      cardano_unit_interval_unref(&value);
      value  = NULL;
      value  = cardano_protocol_parameters_get_max_pledge_leverage(full);
      result = value == NULL ? cardano_protocol_param_update_set_max_pledge_leverage_unbounded(output) : cardano_protocol_param_update_set_max_pledge_leverage(output, value);
    }
  }
  cardano_unit_interval_unref(&value);
  return result;
}

/** \brief Transfer explicit-null bootstrap rounds. Full getter pointers borrow
 * their scalar storage only while the full parameter owner remains alive.
 */
static cardano_error_t
transfer_round(cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  if ((shape != NULL) && !cardano_protocol_param_update_has_peras_bootstrap_round(shape))
  {
    return CARDANO_SUCCESS;
  }
  uint64_t value = 0U;
  if (importing)
  {
    if (cardano_protocol_param_update_is_peras_bootstrap_round_null(shape))
    {
      return cardano_protocol_parameters_set_peras_bootstrap_round(full, NULL);
    }
    cardano_error_t result = cardano_protocol_param_update_get_peras_bootstrap_round(shape, &value);
    return result == CARDANO_SUCCESS ? cardano_protocol_parameters_set_peras_bootstrap_round(full, &value) : result;
  }
  const uint64_t* actual = cardano_protocol_parameters_get_peras_bootstrap_round(full);
  return actual == NULL ? cardano_protocol_param_update_set_peras_bootstrap_round_null(output) : cardano_protocol_param_update_set_peras_bootstrap_round(output, actual);
}

/* STATIC CONSTANTS **********************************************************/

static const uint_field_t uint_fields[] = {
  { true, cardano_protocol_param_update_get_min_fee_a, cardano_protocol_parameters_set_min_fee_a, cardano_protocol_parameters_get_min_fee_a, cardano_protocol_param_update_set_min_fee_a },
  { true, cardano_protocol_param_update_get_min_fee_b, cardano_protocol_parameters_set_min_fee_b, cardano_protocol_parameters_get_min_fee_b, cardano_protocol_param_update_set_min_fee_b },
  { true, cardano_protocol_param_update_get_max_block_body_size, cardano_protocol_parameters_set_max_block_body_size, cardano_protocol_parameters_get_max_block_body_size, cardano_protocol_param_update_set_max_block_body_size },
  { true, cardano_protocol_param_update_get_max_tx_size, cardano_protocol_parameters_set_max_tx_size, cardano_protocol_parameters_get_max_tx_size, cardano_protocol_param_update_set_max_tx_size },
  { true, cardano_protocol_param_update_get_max_block_header_size, cardano_protocol_parameters_set_max_block_header_size, cardano_protocol_parameters_get_max_block_header_size, cardano_protocol_param_update_set_max_block_header_size },
  { true, cardano_protocol_param_update_get_key_deposit, cardano_protocol_parameters_set_key_deposit, cardano_protocol_parameters_get_key_deposit, cardano_protocol_param_update_set_key_deposit },
  { true, cardano_protocol_param_update_get_pool_deposit, cardano_protocol_parameters_set_pool_deposit, cardano_protocol_parameters_get_pool_deposit, cardano_protocol_param_update_set_pool_deposit },
  { true, cardano_protocol_param_update_get_max_epoch, cardano_protocol_parameters_set_max_epoch, cardano_protocol_parameters_get_max_epoch, cardano_protocol_param_update_set_max_epoch },
  { true, cardano_protocol_param_update_get_n_opt, cardano_protocol_parameters_set_n_opt, cardano_protocol_parameters_get_n_opt, cardano_protocol_param_update_set_n_opt },
  { true, cardano_protocol_param_update_get_min_pool_cost, cardano_protocol_parameters_set_min_pool_cost, cardano_protocol_parameters_get_min_pool_cost, cardano_protocol_param_update_set_min_pool_cost },
  { false, cardano_protocol_param_update_get_ada_per_utxo_byte, cardano_protocol_parameters_set_ada_per_utxo_byte, cardano_protocol_parameters_get_ada_per_utxo_byte, cardano_protocol_param_update_set_ada_per_utxo_byte },
  { false, cardano_protocol_param_update_get_collateral_percentage, cardano_protocol_parameters_set_collateral_percentage, cardano_protocol_parameters_get_collateral_percentage, cardano_protocol_param_update_set_collateral_percentage },
  { false, cardano_protocol_param_update_get_max_collateral_inputs, cardano_protocol_parameters_set_max_collateral_inputs, cardano_protocol_parameters_get_max_collateral_inputs, cardano_protocol_param_update_set_max_collateral_inputs },
  { false, cardano_protocol_param_update_get_min_committee_size, cardano_protocol_parameters_set_min_committee_size, cardano_protocol_parameters_get_min_committee_size, cardano_protocol_param_update_set_min_committee_size },
  { false, cardano_protocol_param_update_get_committee_term_limit, cardano_protocol_parameters_set_committee_term_limit, cardano_protocol_parameters_get_committee_term_limit, cardano_protocol_param_update_set_committee_term_limit },
  { false, cardano_protocol_param_update_get_governance_action_validity_period, cardano_protocol_parameters_set_governance_action_validity_period, cardano_protocol_parameters_get_governance_action_validity_period, cardano_protocol_param_update_set_governance_action_validity_period },
  { false, cardano_protocol_param_update_get_governance_action_deposit, cardano_protocol_parameters_set_governance_action_deposit, cardano_protocol_parameters_get_governance_action_deposit, cardano_protocol_param_update_set_governance_action_deposit },
  { false, cardano_protocol_param_update_get_drep_deposit, cardano_protocol_parameters_set_drep_deposit, cardano_protocol_parameters_get_drep_deposit, cardano_protocol_param_update_set_drep_deposit },
  { false, cardano_protocol_param_update_get_drep_inactivity_period, cardano_protocol_parameters_set_drep_inactivity_period, cardano_protocol_parameters_get_drep_inactivity_period, cardano_protocol_param_update_set_drep_inactivity_period },
  { false, cardano_protocol_param_update_get_max_ref_script_size_per_block, cardano_protocol_parameters_set_max_ref_script_size_per_block, cardano_protocol_parameters_get_max_ref_script_size_per_block, cardano_protocol_param_update_set_max_ref_script_size_per_block },
  { false, cardano_protocol_param_update_get_max_ref_script_size_per_tx, cardano_protocol_parameters_set_max_ref_script_size_per_tx, cardano_protocol_parameters_get_max_ref_script_size_per_tx, cardano_protocol_param_update_set_max_ref_script_size_per_tx },
  { false, cardano_protocol_param_update_get_ref_script_cost_stride, cardano_protocol_parameters_set_ref_script_cost_stride, cardano_protocol_parameters_get_ref_script_cost_stride, cardano_protocol_param_update_set_ref_script_cost_stride },
  { false, cardano_protocol_param_update_get_leios_announcement_period_length, cardano_protocol_parameters_set_leios_announcement_period_length, cardano_protocol_parameters_get_leios_announcement_period_length, cardano_protocol_param_update_set_leios_announcement_period_length },
  { false, cardano_protocol_param_update_get_leios_vote_period_length, cardano_protocol_parameters_set_leios_vote_period_length, cardano_protocol_parameters_get_leios_vote_period_length, cardano_protocol_param_update_set_leios_vote_period_length },
  { false, cardano_protocol_param_update_get_leios_diffusion_period_length, cardano_protocol_parameters_set_leios_diffusion_period_length, cardano_protocol_parameters_get_leios_diffusion_period_length, cardano_protocol_param_update_set_leios_diffusion_period_length },
  { false, cardano_protocol_param_update_get_leios_committee_size, cardano_protocol_parameters_set_leios_committee_size, cardano_protocol_parameters_get_leios_committee_size, cardano_protocol_param_update_set_leios_committee_size },
  { false, cardano_protocol_param_update_get_max_endorser_block_references_size, cardano_protocol_parameters_set_max_endorser_block_references_size, cardano_protocol_parameters_get_max_endorser_block_references_size, cardano_protocol_param_update_set_max_endorser_block_references_size },
  { false, cardano_protocol_param_update_get_max_endorser_block_txs_size, cardano_protocol_parameters_set_max_endorser_block_txs_size, cardano_protocol_parameters_get_max_endorser_block_txs_size, cardano_protocol_param_update_set_max_endorser_block_txs_size },
  { false, cardano_protocol_param_update_get_max_ref_script_size_per_endorser_block, cardano_protocol_parameters_set_max_ref_script_size_per_endorser_block, cardano_protocol_parameters_get_max_ref_script_size_per_endorser_block, cardano_protocol_param_update_set_max_ref_script_size_per_endorser_block },
  { false, cardano_protocol_param_update_get_peras_min_candidate_block_age, cardano_protocol_parameters_set_peras_min_candidate_block_age, cardano_protocol_parameters_get_peras_min_candidate_block_age, cardano_protocol_param_update_set_peras_min_candidate_block_age },
  { false, cardano_protocol_param_update_get_peras_cert_boost, cardano_protocol_parameters_set_peras_cert_boost, cardano_protocol_parameters_get_peras_cert_boost, cardano_protocol_param_update_set_peras_cert_boost },
  { false, cardano_protocol_param_update_get_peras_target_committee_size, cardano_protocol_parameters_set_peras_target_committee_size, cardano_protocol_parameters_get_peras_target_committee_size, cardano_protocol_param_update_set_peras_target_committee_size },
  { false, cardano_protocol_param_update_get_ref_inputs_cost_per_multi_asset_policy, cardano_protocol_parameters_set_ref_inputs_cost_per_multi_asset_policy, cardano_protocol_parameters_get_ref_inputs_cost_per_multi_asset_policy, cardano_protocol_param_update_set_ref_inputs_cost_per_multi_asset_policy },
  { false, cardano_protocol_param_update_get_ref_inputs_cost_per_datum_byte, cardano_protocol_parameters_set_ref_inputs_cost_per_datum_byte, cardano_protocol_parameters_get_ref_inputs_cost_per_datum_byte, cardano_protocol_param_update_set_ref_inputs_cost_per_datum_byte },
};

static const buffer_field_t buffer_fields[] = {
  { false, cardano_protocol_param_update_get_extra_entropy, cardano_protocol_parameters_set_extra_entropy, cardano_protocol_parameters_get_extra_entropy, cardano_protocol_param_update_set_extra_entropy },
};

static const costmdls_field_t costmdls_fields[] = {
  { false, cardano_protocol_param_update_get_cost_models, cardano_protocol_parameters_set_cost_models, cardano_protocol_parameters_get_cost_models, cardano_protocol_param_update_set_cost_models },
};

static const drep_voting_thresholds_field_t drep_voting_thresholds_fields[] = {
  { false, cardano_protocol_param_update_get_drep_voting_thresholds, cardano_protocol_parameters_set_drep_voting_thresholds, cardano_protocol_parameters_get_drep_voting_thresholds, cardano_protocol_param_update_set_drep_voting_thresholds },
};

static const ex_unit_prices_field_t ex_unit_prices_fields[] = {
  { false, cardano_protocol_param_update_get_execution_costs, cardano_protocol_parameters_set_execution_costs, cardano_protocol_parameters_get_execution_costs, cardano_protocol_param_update_set_execution_costs },
};

static const ex_units_field_t ex_units_fields[] = {
  { false, cardano_protocol_param_update_get_max_tx_ex_units, cardano_protocol_parameters_set_max_tx_ex_units, cardano_protocol_parameters_get_max_tx_ex_units, cardano_protocol_param_update_set_max_tx_ex_units },
  { false, cardano_protocol_param_update_get_max_block_ex_units, cardano_protocol_parameters_set_max_block_ex_units, cardano_protocol_parameters_get_max_block_ex_units, cardano_protocol_param_update_set_max_block_ex_units },
  { false, cardano_protocol_param_update_get_max_endorser_block_execution_units, cardano_protocol_parameters_set_max_endorser_block_execution_units, cardano_protocol_parameters_get_max_endorser_block_execution_units, cardano_protocol_param_update_set_max_endorser_block_execution_units },
};

static const pool_voting_thresholds_field_t pool_voting_thresholds_fields[] = {
  { false, cardano_protocol_param_update_get_pool_voting_thresholds, cardano_protocol_parameters_set_pool_voting_thresholds, cardano_protocol_parameters_get_pool_voting_thresholds, cardano_protocol_param_update_set_pool_voting_thresholds },
};

static const protocol_version_field_t protocol_version_fields[] = {
  { true, cardano_protocol_param_update_get_protocol_version, cardano_protocol_parameters_set_protocol_version, cardano_protocol_parameters_get_protocol_version, cardano_protocol_param_update_set_protocol_version },
};

static const unit_interval_field_t unit_interval_fields[] = {
  { true, cardano_protocol_param_update_get_pool_pledge_influence, cardano_protocol_parameters_set_pool_pledge_influence, cardano_protocol_parameters_get_pool_pledge_influence, cardano_protocol_param_update_set_pool_pledge_influence },
  { true, cardano_protocol_param_update_get_expansion_rate, cardano_protocol_parameters_set_expansion_rate, cardano_protocol_parameters_get_expansion_rate, cardano_protocol_param_update_set_expansion_rate },
  { true, cardano_protocol_param_update_get_treasury_growth_rate, cardano_protocol_parameters_set_treasury_growth_rate, cardano_protocol_parameters_get_treasury_growth_rate, cardano_protocol_param_update_set_treasury_growth_rate },
  { false, cardano_protocol_param_update_get_d, cardano_protocol_parameters_set_d, cardano_protocol_parameters_get_d, cardano_protocol_param_update_set_d },
  { false, cardano_protocol_param_update_get_ref_script_cost_per_byte, cardano_protocol_parameters_set_ref_script_cost_per_byte, cardano_protocol_parameters_get_ref_script_cost_per_byte, cardano_protocol_param_update_set_ref_script_cost_per_byte },
  { false, cardano_protocol_param_update_get_ref_script_cost_multiplier, cardano_protocol_parameters_set_ref_script_cost_multiplier, cardano_protocol_parameters_get_ref_script_cost_multiplier, cardano_protocol_param_update_set_ref_script_cost_multiplier },
  { false, cardano_protocol_param_update_get_min_pool_margin, cardano_protocol_parameters_set_min_pool_margin, cardano_protocol_parameters_get_min_pool_margin, cardano_protocol_param_update_set_min_pool_margin },
  { false, cardano_protocol_param_update_get_leios_quorum_stake_threshold, cardano_protocol_parameters_set_leios_quorum_stake_threshold, cardano_protocol_parameters_get_leios_quorum_stake_threshold, cardano_protocol_param_update_set_leios_quorum_stake_threshold },
  { false, cardano_protocol_param_update_get_peras_healing_factor, cardano_protocol_parameters_set_peras_healing_factor, cardano_protocol_parameters_get_peras_healing_factor, cardano_protocol_param_update_set_peras_healing_factor },
  { false, cardano_protocol_param_update_get_peras_quorum_threshold_safety_margin, cardano_protocol_parameters_set_peras_quorum_threshold_safety_margin, cardano_protocol_parameters_get_peras_quorum_threshold_safety_margin, cardano_protocol_param_update_set_peras_quorum_threshold_safety_margin },
};

/* STATIC FUNCTIONS **********************************************************/

/** \brief Directional transfer through audited typed native accessors. */
static cardano_error_t
transfer_fields(cardano_protocol_param_update_t* shape, cardano_protocol_parameters_t* full, cardano_protocol_param_update_t* output, bool importing)
{
  cardano_error_t result = CARDANO_SUCCESS;
  for (size_t i = 0U; i < sizeof(uint_fields) / sizeof(uint_fields[0]); ++i)
  {
    result = transfer_uint(&uint_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(buffer_fields) / sizeof(buffer_fields[0]); ++i)
  {
    result = transfer_buffer(&buffer_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(costmdls_fields) / sizeof(costmdls_fields[0]); ++i)
  {
    result = transfer_costmdls(&costmdls_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(drep_voting_thresholds_fields) / sizeof(drep_voting_thresholds_fields[0]); ++i)
  {
    result = transfer_drep_voting_thresholds(&drep_voting_thresholds_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(ex_unit_prices_fields) / sizeof(ex_unit_prices_fields[0]); ++i)
  {
    result = transfer_ex_unit_prices(&ex_unit_prices_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(ex_units_fields) / sizeof(ex_units_fields[0]); ++i)
  {
    result = transfer_ex_units(&ex_units_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(pool_voting_thresholds_fields) / sizeof(pool_voting_thresholds_fields[0]); ++i)
  {
    result = transfer_pool_voting_thresholds(&pool_voting_thresholds_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(protocol_version_fields) / sizeof(protocol_version_fields[0]); ++i)
  {
    result = transfer_protocol_version(&protocol_version_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  for (size_t i = 0U; i < sizeof(unit_interval_fields) / sizeof(unit_interval_fields[0]); ++i)
  {
    result = transfer_unit_interval(&unit_interval_fields[i], shape, full, output, importing);
    if (result != CARDANO_SUCCESS)
    {
      return result;
    }
  }
  result = transfer_max_value_size(shape, full, output, importing);
  if (result == CARDANO_SUCCESS)
  {
    result = transfer_leverage(shape, full, output, importing);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = transfer_round(shape, full, output, importing);
  }
  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_parameters_from_snapshot(const unsigned char* bytes, size_t size, cardano_protocol_parameters_t** output)
{
  *output                                 = NULL;
  cardano_protocol_param_update_t* shape  = NULL;
  cardano_error_t                  result = read_snapshot(bytes, size, &shape);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_protocol_parameters_new(output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = transfer_fields(shape, *output, NULL, true);
  }
  if (result != CARDANO_SUCCESS)
  {
    cardano_protocol_parameters_unref(output);
  }
  cardano_protocol_param_update_unref(&shape);
  return (unsigned int)result;
}

unsigned int
cometa_parameters_to_snapshot(cardano_protocol_parameters_t* parameters, const unsigned char* template_bytes, size_t template_size, cardano_buffer_t** output)
{
  *output = NULL;
  if ((parameters == NULL) || ((template_bytes == NULL) != (template_size == 0U)))
  {
    return CARDANO_ERROR_INVALID_ARGUMENT;
  }
  cardano_protocol_param_update_t* shape  = NULL;
  cardano_protocol_param_update_t* fresh  = NULL;
  cardano_cbor_writer_t*           writer = NULL;
  cardano_error_t                  result = template_bytes == NULL ? CARDANO_SUCCESS : read_snapshot(template_bytes, template_size, &shape);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_protocol_param_update_new(&fresh);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = transfer_fields(shape, parameters, fresh, false);
  }
  if (result == CARDANO_SUCCESS)
  {
    writer = cardano_cbor_writer_new();
    result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_protocol_param_update_to_cbor(fresh, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
  cardano_cbor_writer_unref(&writer);
  cardano_protocol_param_update_unref(&fresh);
  cardano_protocol_param_update_unref(&shape);
  return (unsigned int)result;
}

unsigned int
cometa_parameters_update_to_plutus_data(const unsigned char* bytes, size_t size, cardano_buffer_t** output)
{
  if (output == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  *output = NULL;

  if (bytes == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  cardano_protocol_param_update_t* update = NULL;
  cardano_plutus_data_t*           data   = NULL;
  cardano_cbor_writer_t*           writer = NULL;
  cardano_error_t                  result = read_snapshot(bytes, size, &update);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_protocol_param_update_to_plutus_data(update, &data);
  }

  if (result == CARDANO_SUCCESS)
  {
    writer = cardano_cbor_writer_new();
    result = writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_plutus_data_to_cbor(data, writer);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }

  cardano_cbor_writer_unref(&writer);
  cardano_plutus_data_unref(&data);
  cardano_protocol_param_update_unref(&update);

  if (result != CARDANO_SUCCESS)
  {
    cardano_buffer_unref(output);
    *output = NULL;
  }

  return (unsigned int)result;
}
