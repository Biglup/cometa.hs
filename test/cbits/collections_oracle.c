/**
 * \file collections_oracle.c
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

/* DEFINITIONS ***************************************************************/

/* Test-only semantic oracle. Inputs/output are borrowed spans. Every native
 * object remains operation-scoped, including failure paths. The C decoder
 * constructs real typed collection entries; re-encoding establishes sorting,
 * duplicates, zero, bounds and tag behavior independently of Haskell cborg. */
int
cometa_test_collection_roundtrip(
  int                  kind,
  const unsigned char* input,
  size_t               size,
  unsigned char*       output,
  size_t               capacity,
  size_t*              output_size)
{
  cardano_cbor_reader_t*      reader      = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t*      writer      = cardano_cbor_writer_new();
  cardano_asset_name_map_t*   names       = NULL;
  cardano_withdrawal_map_t*   withdrawals = NULL;
  cardano_blake2b_hash_set_t* hashes      = NULL;
  cardano_error_t             result      = CARDANO_ERROR_INVALID_ARGUMENT;

  if (reader == NULL || writer == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }

  switch (kind)
  {
    case 0:
      result = cardano_asset_name_map_from_cbor(reader, &names);
      if (result == CARDANO_SUCCESS)
        result = cardano_asset_name_map_to_cbor(names, writer);
      break;
    case 1:
      result = cardano_withdrawal_map_from_cbor(reader, &withdrawals);
      if (result == CARDANO_SUCCESS)
        result = cardano_withdrawal_map_to_cbor(withdrawals, writer);
      break;
    case 2:
      result = cardano_blake2b_hash_set_from_cbor(reader, &hashes);
      if (result == CARDANO_SUCCESS)
        result = cardano_blake2b_hash_set_to_cbor(hashes, writer);
      break;
  }

  if (result == CARDANO_SUCCESS)
  {
    *output_size = cardano_cbor_writer_get_encode_size(writer);
    result       = cardano_cbor_writer_encode(writer, output, capacity);
  }

cleanup:
  cardano_asset_name_map_unref(&names);
  cardano_withdrawal_map_unref(&withdrawals);
  cardano_blake2b_hash_set_unref(&hashes);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  return result;
}
