/**
 * \file cometa_provider_runtime.h
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

#ifndef BIGLUP_LABS_COMETA_PROVIDER_RUNTIME_H
#define BIGLUP_LABS_COMETA_PROVIDER_RUNTIME_H
/* INCLUDES ******************************************************************/
#include "cometa_runtime.h"
#include <cardano/providers/provider.h>
/* DECLARATIONS **************************************************************/
/** \brief Construct an owned provider; its context retains runtime until final destruction.
 * \param runtime Borrowed callback runtime, valid through construction.
 * \param name Borrowed UTF8 diagnostic name, without NUL.
 * \param name_size Name byte count, at most255.
 * \param magic Explicit network magic.
 * \param output Owned provider output, initialized NULL.
 * \return Native status; failure releases every partial reference.
 */
unsigned int cometa_provider_runtime_new(cometa_runtime_t* runtime, const unsigned char* name, size_t name_size, uint32_t magic, cardano_provider_t** output);
/** \brief Dispatch through actual native provider methods; inputs borrowed, reply owned on success.
 * \param runtime Borrowed active runtime.
 * \param name Borrowed provider name.
 * \param name_size Name byte length.
 * \param magic Explicit network magic.
 * \param operation Private operation zero through nine.
 * \param input Complete encoded request.
 * \param size Request byte length.
 * \param output Owned reply buffer; initialized NULL and released on failure.
 * \return Native status. All typed temporaries and provider are released before return.
 */
unsigned int cometa_provider_runtime_call(cometa_runtime_t* runtime, const unsigned char* name, size_t name_size, uint32_t magic, uint32_t operation, const unsigned char* input, size_t size, cardano_buffer_t** output);
#endif
