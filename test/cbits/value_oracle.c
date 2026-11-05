/**
 * \file value_oracle.c
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

#include <cardano/assets/asset_id.h>
#include <cardano/assets/asset_name.h>
#include <cardano/assets/multi_asset.h>
#include <cardano/crypto/blake2b_hash.h>
#include <cardano/transaction_body/value.h>

#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/* The retained multiasset reference is released independently of the value.
 * Missing quantities compare as zero, matching the Haskell semantic bundle. */
static int
matches(cardano_value_t* value, cardano_blake2b_hash_t* policy, cardano_asset_name_t* name, int64_t coin, int64_t amount)
{
  if (value == NULL)
  {
    return 0;
  }

  cardano_multi_asset_t* assets = cardano_value_get_multi_asset(value);
  int64_t                actual = 0;
  cardano_error_t        result = cardano_multi_asset_get(assets, policy, name, &actual);
  int                    agrees = (cardano_value_get_coin(value) == coin) &&
    (((result == CARDANO_SUCCESS) && (actual == amount)) || ((result == CARDANO_ERROR_ELEMENT_NOT_FOUND) && (amount == 0)));

  cardano_multi_asset_unref(&assets);

  return agrees;
}

/* DEFINITIONS ***************************************************************/

/* Test-only borrowed input spans and int64 values. Haskell verifies that every
 * input, sum and difference fits int64 BEFORE casting. This is not checked C
 * arithmetic. Constructors copy/retain inputs; each local obligation is released
 * even on failure, and no mutable native object escapes this function. */
int
cometa_test_value_agreement(
  const unsigned char* policy_bytes,
  const unsigned char* name_bytes,
  size_t               name_size,
  int64_t              left_coin,
  int64_t              left_amount,
  int64_t              right_coin,
  int64_t              right_amount,
  int64_t              sum_coin,
  int64_t              sum_amount,
  int64_t              delta_coin,
  int64_t              delta_amount)
{
  cardano_blake2b_hash_t* policy = NULL;
  cardano_asset_name_t*   name   = NULL;
  cardano_asset_id_t*     asset  = NULL;
  cardano_asset_id_t*     ada    = NULL;
  cardano_value_t*        left   = NULL;
  cardano_value_t*        right  = NULL;
  cardano_value_t*        sum    = NULL;
  cardano_value_t*        delta  = NULL;
  cardano_error_t         result = cardano_blake2b_hash_from_bytes(policy_bytes, 28, &policy);

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_asset_name_from_bytes(name_bytes, name_size, &name);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_asset_id_new(policy, name, &asset);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_asset_id_new_lovelace(&ada);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_new(left_coin, NULL, &left);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_new(right_coin, NULL, &right);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_add_asset(left, policy, name, left_amount);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_add_asset(right, policy, name, right_amount);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_add(left, right, &sum);
  }

  if (result == CARDANO_SUCCESS)
  {
    result = cardano_value_subtract(left, right, &delta);
  }

  int agrees = 0;

  if (result == CARDANO_SUCCESS)
  {
    const unsigned char* asset_bytes = cardano_asset_id_get_bytes(asset);
    agrees                           = (cardano_asset_name_get_bytes_size(name) == name_size) &&
      (memcmp(cardano_asset_name_get_bytes(name), name_bytes, name_size) == 0) &&
      (cardano_asset_id_get_bytes_size(asset) == 28U + name_size) &&
      (memcmp(asset_bytes, policy_bytes, 28) == 0) &&
      (memcmp(asset_bytes + 28, name_bytes, name_size) == 0) &&
      cardano_asset_id_is_lovelace(ada) && !cardano_asset_id_is_lovelace(asset) &&
      (cardano_asset_id_get_bytes_size(ada) == 0) &&
      matches(left, policy, name, left_coin, left_amount) &&
      matches(right, policy, name, right_coin, right_amount) &&
      matches(sum, policy, name, sum_coin, sum_amount) &&
      matches(delta, policy, name, delta_coin, delta_amount);
  }

  cardano_value_unref(&delta);
  cardano_value_unref(&sum);
  cardano_value_unref(&right);
  cardano_value_unref(&left);
  cardano_asset_id_unref(&ada);
  cardano_asset_id_unref(&asset);
  cardano_asset_name_unref(&name);
  cardano_blake2b_hash_unref(&policy);

  return agrees;
}
