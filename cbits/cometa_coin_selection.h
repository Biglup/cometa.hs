/**
 * \file cometa_coin_selection.h
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

#ifndef BIGLUP_LABS_COMETA_COIN_SELECTION_H
#define BIGLUP_LABS_COMETA_COIN_SELECTION_H

/* INCLUDES ******************************************************************/

#include "cometa_runtime.h"
#include <cardano/cardano.h>
#include <stddef.h>
#include <stdint.h>

/* DECLARATIONS **************************************************************/

/**
 * \brief Create a native selector adopting an independently retained runtime.
 * \param runtime Borrowed live runtime, serialized by the caller's operation gate.
 * \param parameter_template Optional borrowed availability snapshot copied here.
 * \param template_size Byte count, zero when no originating snapshot is known.
 * \param output Owned selector on success; NULL on failure. Factory failure
 * releases its runtime reference and any copied template; caller retains its own.
 * \return Native status. The context retains both runtime and optional template
 * until final native selector destruction. Callback request pointers borrow only
 * until synchronous return. Success transfers three independent list references.
 */
unsigned int cometa_coin_selector_new(cometa_runtime_t* runtime, const unsigned char* parameter_template, size_t template_size, cardano_coin_selector_t** output);

/**
 * \brief Internal native-dispatch integration harness and future adapter caller.
 * \param runtime Live callback runtime; retain before invoking native callbacks.
 * \param bytes Borrowed six-field request snapshot until synchronous return.
 * \param size Request size in bytes.
 * \param output Owned three-list result snapshot on success, NULL on failure.
 * \return Native status. Decodes typed native values, calls actual selector
 * dispatch, snapshots all returned native collections, and releases every owner
 * on success, malformed reply, partial output failure and callback unwind.
 */
unsigned int cometa_coin_selection_invoke(cometa_runtime_t* runtime, const unsigned char* bytes, size_t size, cardano_buffer_t** output);

/**
 * \brief Execute an actual native algorithm with operation-local ownership.
 * \param algorithm 0 largest-first, 1 secure-seeded random-improve, 2 seeded.
 * \param seed Seed for algorithm 2, ignored otherwise; replayed on each call.
 * \param strategy 0 minimal or 1 optimal, for algorithm 2 only.
 * \param bytes Borrowed validated request snapshot, including full parameters.
 * \param size Complete request size.
 * \param output Owned result buffer on success, NULL on failure.
 * \return Native status. Constructor, request fields, and all three result
 * lists are released synchronously before return, including partial failures.
 */
unsigned int cometa_coin_selection_native(unsigned int algorithm, uint64_t seed, unsigned int strategy, const unsigned char* bytes, size_t size, cardano_buffer_t** output);

/**
 * \brief Compute minimum Ada with the pinned native fee utility.
 * \param bytes Borrowed fresh semantic output CBOR until return.
 * \param size Complete output byte count.
 * \param coins_per_byte Unsigned lovelace price per UTxO byte.
 * \param minimum Required lovelace on success. No native object escapes.
 * \return Native status; excessive multiplication bounds return integer overflow
 * rather than accepting native unsigned wraparound as a valid minimum.
 */
unsigned int cometa_coin_selection_minimum_ada(const unsigned char* bytes, size_t size, uint64_t coins_per_byte, uint64_t* minimum);

#endif /* BIGLUP_LABS_COMETA_COIN_SELECTION_H */
