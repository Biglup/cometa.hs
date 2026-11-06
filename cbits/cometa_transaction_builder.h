/**
 * \file cometa_transaction_builder.h
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

#ifndef COMETA_TRANSACTION_BUILDER_H
#define COMETA_TRANSACTION_BUILDER_H

#include "cometa_runtime.h"
#include <cardano/cardano.h>

/**
 * \brief Build a fresh transaction with scoped native callback adapters.
 * \param selector Borrowed active runtime, or NULL for the native default.
 * \param evaluator Borrowed active runtime, or NULL for the native default.
 * \param config Borrowed complete configuration snapshot.
 * \param config_size Configuration byte length.
 * \param plan Borrowed validated instruction snapshot.
 * \param plan_size Plan byte length.
 * \param output Owned transaction CBOR on success, NULL on failure.
 * \param diagnostic Owned copied builder diagnostic, possibly NULL.
 * \param key_count Unique native signing keys plus explicit padding on success.
 * \return Native status. All factories, callbacks and owner destruction finish
 * before return. Context gates must stay active for this entire operation.
 */
unsigned int cometa_transaction_builder_build(cometa_runtime_t* selector, cometa_runtime_t* evaluator, const unsigned char* config, size_t config_size, const unsigned char* plan, size_t plan_size, cardano_buffer_t** output, cardano_buffer_t** diagnostic, uint64_t* key_count);
#endif
