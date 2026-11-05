/**
 * \file cometa_script.c
 *
 * \author angel.castillo
 * \date   Nov 04, 2026
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

#include "cometa_script.h"

#include <cardano/cbor/cbor_reader.h>
#include <cardano/plutus_data/plutus_list.h>
#include <cardano/uplc/uplc_apply_params.h>
#include <stdio.h>

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_script_apply_params(
  const unsigned char* script,
  size_t               script_size,
  const unsigned char* params,
  size_t               params_size,
  cardano_buffer_t**   output,
  char*                error,
  size_t               error_size)
{
  *output                       = NULL;
  cardano_cbor_reader_t* reader = cardano_cbor_reader_new(params, params_size);
  cardano_plutus_list_t* list   = NULL;
  cardano_error_t        result = CARDANO_SUCCESS;

  if (reader == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }
  else
  {
    result = cardano_plutus_list_from_cbor(reader, &list);
    if (result == CARDANO_SUCCESS)
    {
      size_t remaining = 0U;
      result           = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
      if ((result == CARDANO_SUCCESS) && (remaining != 0U))
      {
        result = CARDANO_ERROR_DECODING;
      }
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_uplc_apply_params_to_script(list, script, script_size, output);
    }
  }

  if ((result != CARDANO_SUCCESS) && (error != NULL) && (error_size > 0U))
  {
    const char* message = reader == NULL ? "" : cardano_cbor_reader_get_last_error(reader);
    (void)snprintf(error, error_size, "%s", message[0] == '\0' ? cardano_error_to_string(result) : message);
  }

  cardano_plutus_list_unref(&list);
  cardano_cbor_reader_unref(&reader);

  return (unsigned int)result;
}
