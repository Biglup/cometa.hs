/**
 * \file cometa_sub_transaction_builder.h
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

#ifndef BIGLUP_LABS_COMETA_SUB_TRANSACTION_BUILDER_H
#define BIGLUP_LABS_COMETA_SUB_TRANSACTION_BUILDER_H

/* INCLUDES ******************************************************************/

#include "cometa_runtime.h"
#include <cardano/cardano.h>
#include <stddef.h>

/* DECLARATIONS **************************************************************/

/**
 * \brief Build a sub-transaction with operation-scoped deferred callbacks.
 * \param[in] deferred Borrowed active runtime, rooted through builder destruction.
 * \param[in] config Borrowed parameter, network and slot configuration snapshot.
 * \param[in] config_size Configuration byte count.
 * \param[in] plan Borrowed validated sub-transaction instruction snapshot.
 * \param[in] plan_size Instruction snapshot byte count.
 * \param[out] output Owned complete sub-transaction CBOR on success; NULL on failure.
 * \param[out] diagnostic Owned copied native diagnostic on failure when allocated.
 * \return Native status. All builders, retained children and callback contexts
 * are destroyed before returning; caller keeps the runtime gate active until then.
 */
unsigned int cometa_sub_transaction_builder_build(cometa_runtime_t* deferred, const unsigned char* config, size_t config_size, const unsigned char* plan, size_t plan_size, cardano_buffer_t** output, cardano_buffer_t** diagnostic);

#endif
