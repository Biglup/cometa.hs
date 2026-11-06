/**
 * \file parameter_snapshot_oracle.c
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

/* DEFINITIONS ***************************************************************/

/**
 * \brief Exercise production snapshot conversion with fresh full parameters.
 * \param bytes Borrowed input snapshot through synchronous return.
 * \param size Complete snapshot length.
 * \param mode 0 known-origin, 1 mutate native min-fee A, 2 native-origin export.
 * \param output Owned result buffer on success; NULL on any failure.
 * \return Native status. Mode1 proves export uses actual typed native getters,
 * not a cached/echoed template. All full parameter references are released.
 */
unsigned int
cometa_test_parameter_snapshot(const unsigned char* bytes, size_t size, unsigned int mode, cardano_buffer_t** output)
{
  *output                                   = NULL;
  cardano_protocol_parameters_t* parameters = NULL;
  cardano_error_t                result     = (cardano_error_t)cometa_parameters_from_snapshot(bytes, size, &parameters);
  if ((result == CARDANO_SUCCESS) && (mode == 1U))
  {
    result = cardano_protocol_parameters_set_min_fee_a(parameters, cardano_protocol_parameters_get_min_fee_a(parameters) + 1U);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_parameters_to_snapshot(parameters, mode == 2U ? NULL : bytes, mode == 2U ? 0U : size, output);
  }
  cardano_protocol_parameters_unref(&parameters);
  return (unsigned int)result;
}
