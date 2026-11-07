/**
 * \file cometa_cip8.c
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

#ifndef COMETA_CIP8_H
#define COMETA_CIP8_H
#include <cardano/buffer.h>
#include <cardano/crypto/ed25519_private_key.h>

/** Borrow inputs until return. kind 0 binds an address, 1 a key hash.
 * Both initialized output slots own their buffers; release each with buffer_unref.
 * Temporary address/hash objects are always released. No callbacks or retention.
 */
unsigned int cometa_cip8_sign(const cardano_ed25519_private_key_t* key, unsigned int kind, const unsigned char* binding, size_t binding_size, const unsigned char* message, size_t message_size, cardano_buffer_t** sign1, cardano_buffer_t** cose_key);
#endif
