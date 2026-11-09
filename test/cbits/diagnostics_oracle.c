/**
 * \file diagnostics_oracle.c
 *
 * \author angel.castillo
 * \date   Nov 09, 2026
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

/* DEFINITIONS ***************************************************************/

/**
 * \brief Returns a borrowed static diagnostic label; no allocation or ownership transfer.
 */
const char*
cometa_test_diagnostic_label(unsigned int category, uint32_t value)
{
  switch (category)
  {
    case 0:
      return cardano_network_magic_to_string((cardano_network_magic_t)value);
    case 1:
      return cardano_cert_type_to_string((cardano_cert_type_t)value);
    case 2:
      return cardano_native_script_type_to_string((cardano_native_script_type_t)value);
    case 3:
      return cardano_vote_to_string((cardano_vote_t)value);
    case 4:
      return cardano_voter_type_to_string((cardano_voter_type_t)value);
    default:
      return "unknown";
  }
}
