/**
 * \file cometa_building.h
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

#ifndef BIGLUP_LABS_COMETA_BUILDING_H
#define BIGLUP_LABS_COMETA_BUILDING_H

/* INCLUDES ******************************************************************/

#include <cardano/cardano.h>
#include <stddef.h>

/* DECLARATIONS **************************************************************/

/**
 * \brief Marshal standalone building utilities through fresh native values.
 * \param operation 0 minimum fee, 1 reference fee, 2 implicit coin, 3 script
 * data hash, 4 base fee, 5 subtransaction implicit coin. Internal CBOR tuples carry domain values, never pointers.
 * \param bytes Borrowed request bytes until synchronous return.
 * \param size Complete request byte count; trailing input is rejected.
 * \param output Owned CBOR result buffer on success; NULL on failure. All native
 * objects and retained getters are released on every exit. No callbacks occur.
 * \return Native status. Unknown operations return invalid argument.
 */
unsigned int cometa_building_compute(unsigned int operation, const unsigned char* bytes, size_t size, cardano_buffer_t** output);

#endif /* BIGLUP_LABS_COMETA_BUILDING_H */
