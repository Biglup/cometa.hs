/**
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
#ifndef COMETA_INSPECTION_H
#define COMETA_INSPECTION_H

#include <cardano/cardano.h>

/**
 * \brief Inspect one complete CBOR object with fresh operation-scoped owners.
 * \param operation 0 transaction, 1 subtransaction, 2 body, 3 subtransaction body.
 * \param input Borrowed complete CBOR bytes, valid through return.
 * \param size Byte count of input.
 * \param output Transferred JSON byte buffer on success, NULL on failure.
 * \return Native status; every reader, parsed object and writer is released.
 */
unsigned int cometa_inspection_compute(unsigned int operation, const unsigned char* input, size_t size, cardano_buffer_t** output);
#endif
