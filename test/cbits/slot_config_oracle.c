/**
 * \file slot_config_oracle.c
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

#include <cardano/time.h>

/* DEFINITIONS ***************************************************************/

/** \brief Inspect constants directly without copying them into the oracle. */
uint64_t
cometa_test_slot_preset(unsigned int network, unsigned int field)
{
  const cardano_slot_config_t* config = network == 0U ? &CARDANO_MAINNET_SLOT_CONFIG
    : network == 1U                                   ? &CARDANO_PREVIEW_SLOT_CONFIG
                                                      : &CARDANO_PREPROD_SLOT_CONFIG;
  return field == 0U ? config->zero_time : field == 1U ? config->zero_slot
                                                       : config->slot_length;
}

/** \brief Compare bounded valid inputs with the native linear conversion. */
uint64_t
cometa_test_slot_begin(uint64_t time, uint64_t slot, uint64_t length, uint64_t value)
{
  const cardano_slot_config_t config = { time, slot, length };
  return slot_to_begin_unix_time(value, &config);
}

/** \brief Compare slot inclusion at native millisecond precision. */
uint64_t
cometa_test_slot_enclosing(uint64_t time, uint64_t slot, uint64_t length, uint64_t value)
{
  const cardano_slot_config_t config = { time, slot, length };
  return unix_time_to_enclosing_slot(value, &config);
}
