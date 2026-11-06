/**
 * \file cometa_contextual_transaction.h
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

#ifndef BIGLUP_LABS_COMETA_CONTEXTUAL_TRANSACTION_H
#define BIGLUP_LABS_COMETA_CONTEXTUAL_TRANSACTION_H
#include <cardano/buffer.h>
#include <stdint.h>

/** Borrow all input buffers until synchronous return. The certificate index is
 * initialized even on failure. Temporary native objects never escape. */
unsigned int cometa_contextual_certificate_index(const unsigned char* certificates, size_t certificates_size, const unsigned char* target, size_t target_size, uint64_t* index);

/** Borrow input buffers, parse independent snapshots, and transfer one owned
 * serialized hash-set buffer on success. Output is NULL on every failure. */
unsigned int cometa_contextual_required_keys(const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, cardano_buffer_t** output);
#endif
