/**
 * \file protocol_values_oracle.c
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
#include <stdint.h>
#include <string.h>

/* DEFINITIONS ***************************************************************/

/**
 * \brief Construct protocol values from typed numbers, then encode with native
 * codecs. No input CBOR is decoded by this oracle. The caller owns output;
 * constructors retain child references and all local obligations are released.
 */
int
cometa_test_protocol_values_oracle(
  uint8_t        kind,
  uint64_t       first,
  uint64_t       second,
  unsigned char* output,
  size_t         capacity,
  size_t*        output_size)
{
  cardano_error_t                   result       = CARDANO_SUCCESS;
  cardano_cbor_writer_t*            writer       = cardano_cbor_writer_new();
  cardano_unit_interval_t*          rational     = NULL;
  cardano_ex_units_t*               budget       = NULL;
  cardano_protocol_version_t*       version      = NULL;
  cardano_ex_unit_prices_t*         prices       = NULL;
  cardano_pool_voting_thresholds_t* pool         = NULL;
  cardano_drep_voting_thresholds_t* drep         = NULL;
  cardano_cost_model_t*             model        = NULL;
  cardano_costmdls_t*               models       = NULL;
  cardano_buffer_t*                 views        = NULL;
  cardano_unit_interval_t*          other        = NULL;
  const int64_t                     costs[]      = { -1, 0, INT64_MAX };
  const int64_t                     view_costs[] = { INT64_MIN, -1, 0, INT64_MAX };

  if (writer == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  if ((kind == 0U) || (kind == 3U) || (kind == 4U) || (kind == 5U))
  {
    result = cardano_unit_interval_new(first, second, &rational);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  if ((kind == 3U) || (kind == 4U) || (kind == 5U))
  {
    result = cardano_unit_interval_new(second, first + second, &other);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }

  switch (kind)
  {
    case 0:
      result = cardano_unit_interval_to_cbor(rational, writer);
      break;
    case 1:
      result = cardano_ex_units_new(first, second, &budget);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_ex_units_to_cbor(budget, writer);
      }
      break;
    case 2:
      result = cardano_protocol_version_new(first, second, &version);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_protocol_version_to_cbor(version, writer);
      }
      break;
    case 3:
      result = cardano_ex_unit_prices_new(rational, other, &prices);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_ex_unit_prices_to_cbor(prices, writer);
      }
      break;
    case 4:
      result = cardano_pool_voting_thresholds_new(rational, other, rational, other, rational, &pool);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_pool_voting_thresholds_to_cbor(pool, writer);
      }
      break;
    case 5:
      result = cardano_drep_voting_thresholds_new(rational, other, rational, other, rational, other, rational, other, rational, other, &drep);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_drep_voting_thresholds_to_cbor(drep, writer);
      }
      break;
    case 6:
      result = cardano_cost_model_new(CARDANO_PLUTUS_LANGUAGE_VERSION_V1, costs, 3, &model);
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_costmdls_new(&models);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_costmdls_insert(models, model);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_costmdls_to_cbor(models, writer);
      }
      break;
    case 7:
      result = cardano_costmdls_new(&models);
      for (uint8_t language = 0; (language < 5) && (result == CARDANO_SUCCESS); ++language)
      {
        if ((first & (1U << language)) == 0)
        {
          continue;
        }
        if (language == 4)
        {
          const unsigned char    future[]      = { 0x18, 0xff, 0x84, 0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x20, 0, 0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
          cardano_cbor_reader_t* future_reader = cardano_cbor_reader_new(future, sizeof(future));
          if (future_reader == NULL)
          {
            result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
          }
          else
          {
            result = cardano_cost_model_from_cbor(future_reader, &model);
            cardano_cbor_reader_unref(&future_reader);
          }
        }
        else
        {
          result = cardano_cost_model_new((cardano_plutus_language_version_t)language, view_costs, 4, &model);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_costmdls_insert(models, model);
        }
        cardano_cost_model_unref(&model);
        model = NULL; /* The models collection may retain the released object. */
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_costmdls_get_language_views_encoding(models, &views);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_cbor_writer_write_encoded(writer, cardano_buffer_get_data(views), cardano_buffer_get_size(views));
      }
      break;
    default:
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      break;
  }

  if (result == CARDANO_SUCCESS)
  {
    *output_size = cardano_cbor_writer_get_encode_size(writer);
    result       = cardano_cbor_writer_encode(writer, output, capacity);
  }

cleanup:
  cardano_buffer_unref(&views);
  cardano_costmdls_unref(&models);
  cardano_cost_model_unref(&model);
  cardano_drep_voting_thresholds_unref(&drep);
  cardano_pool_voting_thresholds_unref(&pool);
  cardano_ex_unit_prices_unref(&prices);
  cardano_protocol_version_unref(&version);
  cardano_ex_units_unref(&budget);
  cardano_unit_interval_unref(&other);
  cardano_unit_interval_unref(&rational);
  cardano_cbor_writer_unref(&writer);
  return result;
}
