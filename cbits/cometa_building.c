/**
 * \file cometa_building.c
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

#include "cometa_building.h"
#include "cometa_parameters.h"

/* STATIC FUNCTIONS **********************************************************/

/** \brief Decode a retained UTxO list; release each local item after insertion. */
static cardano_error_t
read_utxos(cardano_cbor_reader_t* reader, cardano_utxo_list_t** output)
{
  int64_t         count  = 0;
  cardano_error_t result = cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS && count < 0)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_utxo_list_new(output);
  }
  for (int64_t i = 0; result == CARDANO_SUCCESS && i < count; ++i)
  {
    cardano_utxo_t* item = NULL;
    result               = cardano_utxo_from_cbor(reader, &item);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_list_add(*output, item);
    }
    cardano_utxo_unref(&item);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  return result;
}

/** \brief Materialize one owned parameter set from its encoded snapshot. */
static cardano_error_t
read_parameters(cardano_cbor_reader_t* reader, cardano_protocol_parameters_t** output)
{
  cardano_buffer_t* bytes  = NULL;
  cardano_error_t   result = cardano_cbor_reader_read_encoded_value(reader, &bytes);
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_parameters_from_snapshot(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), output);
  }
  cardano_buffer_unref(&bytes);
  return result;
}

/** \brief Hash exact native witness fields, releasing both retained getters. */
static cardano_error_t
write_script_hash(cardano_cbor_reader_t* reader, cardano_cbor_writer_t* writer)
{
  cardano_costmdls_t*        models    = NULL;
  cardano_witness_set_t*     witnesses = NULL;
  cardano_blake2b_hash_t*    hash      = NULL;
  cardano_plutus_data_set_t* datums    = NULL;
  cardano_redeemer_list_t*   redeemers = NULL;
  cardano_error_t            result    = cardano_costmdls_from_cbor(reader, &models);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_witness_set_from_cbor(reader, &witnesses);
  }
  if (result == CARDANO_SUCCESS)
  {
    datums    = cardano_witness_set_get_plutus_data(witnesses);
    redeemers = cardano_witness_set_get_redeemers(witnesses);
    result    = cardano_compute_script_data_hash(models, redeemers, datums, &hash);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = hash == NULL ? cardano_cbor_writer_write_null(writer) : cardano_cbor_writer_write_bytestring(writer, cardano_blake2b_hash_get_data(hash), cardano_blake2b_hash_get_bytes_size(hash));
  }
  cardano_blake2b_hash_unref(&hash);
  cardano_redeemer_list_unref(&redeemers);
  cardano_plutus_data_set_unref(&datums);
  cardano_witness_set_unref(&witnesses);
  cardano_costmdls_unref(&models);
  return result;
}

/** \brief Encode signed imbalance coin and assets without unsigned ledger Value encoding. */
static cardano_error_t
write_imbalance(cardano_cbor_writer_t* writer, cardano_value_t* value)
{
  cardano_multi_asset_t* assets = cardano_value_get_multi_asset(value);
  cardano_error_t        result = cardano_cbor_writer_write_start_array(writer, 2);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_signed_int(writer, cardano_value_get_coin(value));
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_multi_asset_to_cbor(assets, writer);
  }
  cardano_multi_asset_unref(&assets);
  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_building_compute(unsigned int operation, const unsigned char* bytes, size_t size, cardano_buffer_t** output)
{
  *output                                    = NULL;
  cardano_value_t*               imbalance   = NULL;
  cardano_sub_transaction_t*     sub_tx      = NULL;
  cardano_transaction_t*         tx          = NULL;
  cardano_protocol_parameters_t* parameters  = NULL;
  cardano_utxo_list_t*           references  = NULL;
  cardano_cbor_reader_t*         reader      = cardano_cbor_reader_new(bytes, size);
  cardano_cbor_writer_t*         writer      = cardano_cbor_writer_new();
  int64_t                        count       = 0;
  uint64_t                       amount      = 0U;
  uint64_t                       constant    = 0U;
  uint64_t                       coefficient = 0U;
  cardano_implicit_coin_t        implicit    = { 0 };
  cardano_error_t                result      = reader == NULL || writer == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS && (operation > 8U || count != ((operation == 0U || operation == 4U || operation >= 6U) ? 3 : 2)))
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
  }
  if (result == CARDANO_SUCCESS && operation == 3U)
  {
    result = write_script_hash(reader, writer);
  }
  if (result == CARDANO_SUCCESS && operation != 1U && operation != 3U && operation != 5U && operation != 7U)
  {
    result = cardano_transaction_from_cbor(reader, &tx);
  }
  if (result == CARDANO_SUCCESS && (operation == 5U || operation == 7U))
  {
    result = cardano_sub_transaction_from_cbor(reader, &sub_tx);
  }
  if (result == CARDANO_SUCCESS && (operation < 3U || operation >= 5U))
  {
    result = read_parameters(reader, &parameters);
  }
  if (result == CARDANO_SUCCESS && (operation < 2U || operation >= 6U))
  {
    result = read_utxos(reader, &references);
  }
  if (result == CARDANO_SUCCESS && operation == 4U)
  {
    result = cardano_cbor_reader_read_uint(reader, &constant);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_cbor_reader_read_uint(reader, &coefficient);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    switch (operation)
    {
      case 0U:
        result = cardano_compute_transaction_fee(tx, references, parameters, &amount);
        break;
      case 1U:
        result = cardano_compute_script_ref_fee_with_params(references, parameters, &amount);
        break;
      case 2U:
        result = cardano_compute_implicit_coin(tx, parameters, &implicit);
        break;
      case 5U:
        result = cardano_compute_sub_transaction_implicit_coin(sub_tx, parameters, &implicit);
        break;
      case 6U:
        result = cardano_compute_transaction_imbalance(tx, references, parameters, &imbalance);
        break;
      case 7U:
        result = cardano_compute_sub_transaction_imbalance(sub_tx, references, parameters, &imbalance);
        break;
      case 8U:
        result = cardano_compute_transaction_batch_imbalance(tx, references, parameters, &imbalance);
        break;
      case 4U:
        result = cardano_compute_min_fee_without_scripts(tx, constant, coefficient, &amount);
        break;
      default:
        break;
    }
  }
  if (result == CARDANO_SUCCESS && operation != 3U)
  {
    if (operation >= 6U)
    {
      result = write_imbalance(writer, imbalance);
    }
    else if (operation == 2U || operation == 5U)
    {
      result = cardano_cbor_writer_write_start_array(writer, 3);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_cbor_writer_write_uint(writer, implicit.withdrawals);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_cbor_writer_write_uint(writer, implicit.deposits);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_cbor_writer_write_uint(writer, implicit.reclaim_deposits);
      }
    }
    else
    {
      result = cardano_cbor_writer_write_uint(writer, amount);
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  size_t remaining = 0U;
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
    if (result == CARDANO_SUCCESS && remaining != 0U)
    {
      result = CARDANO_ERROR_INVALID_ARGUMENT;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, output);
  }
  cardano_value_unref(&imbalance);
  cardano_utxo_list_unref(&references);
  cardano_protocol_parameters_unref(&parameters);
  cardano_transaction_unref(&tx);
  cardano_sub_transaction_unref(&sub_tx);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return (unsigned int)result;
}
