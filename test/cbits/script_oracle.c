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

#include <cardano/scripts/native_scripts/native_script.h>
#include <cardano/scripts/script.h>
#include <string.h>

/* DEFINITIONS ***************************************************************/

/**
 * \brief Tests typed Haskell script assembly against native parsing, serialization
 * and language-specific hashing. All input spans are borrowed through return;
 * every acquired reference is released on success and failure. No owner escapes.
 */
int
cometa_test_script_agreement(
  const unsigned char* input,
  size_t               input_size,
  const unsigned char* expected_hash,
  const unsigned char* expected_encoding,
  size_t               expected_size)
{
  cardano_cbor_reader_t*  reader  = cardano_cbor_reader_new(input, input_size);
  cardano_cbor_writer_t*  writer  = cardano_cbor_writer_new();
  cardano_script_t*       script  = NULL;
  cardano_blake2b_hash_t* hash    = NULL;
  cardano_buffer_t*       encoded = NULL;
  cardano_error_t         result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  int                     agrees  = 0;

  if ((reader != NULL) && (writer != NULL))
  {
    result = cardano_script_from_cbor(reader, &script);
  }
  if ((result == CARDANO_SUCCESS) && (input_size >= 4U) && (input[1] == 0U))
  {
    cardano_native_script_t*     native = NULL;
    cardano_native_script_type_t type   = CARDANO_NATIVE_SCRIPT_TYPE_REQUIRE_PUBKEY;
    result                              = cardano_script_to_native(script, &native);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_native_script_get_type(native, &type);
      if ((result == CARDANO_SUCCESS) && ((unsigned int)type != input[3]))
      {
        result = CARDANO_ERROR_INVALID_CBOR_VALUE;
      }
      /* Recursive cache invalidation forces serialization and hashing to read
       * parsed semantic fields, rather than forwarding the input encoding. */
      cardano_native_script_clear_cbor_cache(native);
    }
    cardano_native_script_unref(&native);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_script_to_cbor(script, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  }
  if (result == CARDANO_SUCCESS)
  {
    hash   = cardano_script_get_hash(script);
    agrees = (hash != NULL) && (cardano_blake2b_hash_get_bytes_size(hash) == 28U) &&
      (memcmp(cardano_blake2b_hash_get_data(hash), expected_hash, 28U) == 0) &&
      (cardano_buffer_get_size(encoded) == expected_size) &&
      (memcmp(cardano_buffer_get_data(encoded), expected_encoding, expected_size) == 0);
  }

  cardano_buffer_unref(&encoded);
  cardano_blake2b_hash_unref(&hash);
  cardano_script_unref(&script);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);

  return agrees;
}
