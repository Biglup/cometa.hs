/**
 * \file asset_id_oracle.c
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
#include <string.h>

/* DEFINITIONS ***************************************************************/

/* Test-only borrowed byte/hex spans. Each successful constructor transfers one
 * reference, released independently on every exit. Getter spans are borrowed
 * and consumed while their owner is alive. Native hex size includes its NUL. */
int
cometa_test_asset_id_codecs(const unsigned char* bytes, size_t size, const unsigned char* hex, size_t hex_size)
{
  cardano_asset_id_t* binary_asset = NULL;
  cardano_asset_id_t* hex_asset    = NULL;
  int                 agrees       = 0;

  if (cardano_asset_id_from_bytes(bytes, size, &binary_asset) != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  if (cardano_asset_id_from_hex((const char*)hex, hex_size, &hex_asset) != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  agrees = !cardano_asset_id_is_lovelace(binary_asset) && !cardano_asset_id_is_lovelace(hex_asset) &&
    (cardano_asset_id_get_bytes_size(binary_asset) == size) && (cardano_asset_id_get_bytes_size(hex_asset) == size) &&
    (memcmp(cardano_asset_id_get_bytes(binary_asset), bytes, size) == 0) &&
    (memcmp(cardano_asset_id_get_bytes(hex_asset), bytes, size) == 0) &&
    (cardano_asset_id_get_hex_size(binary_asset) == hex_size + 1U) &&
    (cardano_asset_id_get_hex_size(hex_asset) == hex_size + 1U) &&
    (memcmp(cardano_asset_id_get_hex(binary_asset), hex, hex_size) == 0) &&
    (memcmp(cardano_asset_id_get_hex(hex_asset), hex, hex_size) == 0);

cleanup:
  cardano_asset_id_unref(&binary_asset);
  cardano_asset_id_unref(&hex_asset);
  return agrees;
}
