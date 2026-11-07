/**
 * \file cometa_parameters.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_PARAMETERS_H
#define BIGLUP_LABS_INCLUDE_COMETA_PARAMETERS_H

/* INCLUDES ******************************************************************/

#include <cardano/cardano.h>
#include <stddef.h>

/* DECLARATIONS **************************************************************/

/**
 * \brief Materialize a complete owned parameter snapshot through typed setters.
 * \param[in] bytes Borrowed protocol-update-key snapshot CBOR until return.
 * \param[in] size Complete byte count. All required snapshot fields must exist.
 * \param[out] output Owned full parameters on success; NULL on every failure.
 * \return A native status. Missing required fields and max-value-size overflow
 * above INT64_MAX are errors; no parameter defaults are synthesized.
 */
unsigned int cometa_parameters_from_snapshot(const unsigned char* bytes, size_t size, cardano_protocol_parameters_t** output);

/**
 * \brief Snapshot actual typed getters with optional original availability.
 * \param[in] parameters Borrowed full parameters, kept alive until return.
 * \param[in] template_bytes Optional borrowed snapshot defining original field presence.
 * Full native scalars have no presence flags. Values always come from getters; a supplied template controls only presence.
 * Without a template, native scalars are present, optional NULL objects absent,
 * and nullable NULL leverage/bootstrap values explicitly unbounded/unset.
 * \param[in] template_size Byte count of the complete availability template.
 * \param[out] output Owned snapshot buffer on success; NULL on failure.
 * \return Native status. Required missing objects are rejected. All retained getter
 * references are released before return. Full native scalars cannot distinguish
 * unavailable fields from stored zero values; no availability claim is made.
 */
unsigned int cometa_parameters_to_snapshot(cardano_protocol_parameters_t* parameters, const unsigned char* template_bytes, size_t template_size, cardano_buffer_t** output);

/**
 * \brief Convert a sparse protocol update to its ChangedParameters Plutus data.
 * \param[in] bytes Borrowed complete protocol-update CBOR until return.
 * \param[in] size Number of input bytes.
 * \param[out] output Owned Plutus-data CBOR buffer on success; NULL on failure.
 * \return Native status. Temporary update, data and writer owners are released
 * before return. The caller releases the returned buffer.
 */
unsigned int cometa_parameters_update_to_plutus_data(const unsigned char* bytes, size_t size, cardano_buffer_t** output);

#endif /* BIGLUP_LABS_INCLUDE_COMETA_PARAMETERS_H */
