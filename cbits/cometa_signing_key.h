/**
 * \file cometa_signing_key.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_SIGNING_KEY_H
#define BIGLUP_LABS_INCLUDE_COMETA_SIGNING_KEY_H

/* INCLUDES ******************************************************************/

#include <cardano/crypto/ed25519_private_key.h>
#include <stddef.h>

/* DECLARATIONS **************************************************************/

#ifdef __cplusplus
extern "C" {
#endif

/**
 * \brief Import one owned normal seed key from borrowed bytes.
 * \param[in] data Exactly 32 seed bytes, borrowed until return.
 * \param[in] size Byte length of data.
 * \param[out] key Initialized to NULL; receives one owned reference on success.
 * \returns A cardano-c status converted to unsigned int.
 */
unsigned int cometa_signing_key_from_normal_bytes(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key);

/**
 * \brief Import one owned extended scalar/IV key from borrowed bytes.
 * \param[in] data Exactly 64 expanded bytes, borrowed until return.
 * \param[in] size Byte length of data.
 * \param[out] key Initialized to NULL; receives one owned reference on success.
 * \returns A cardano-c status converted to unsigned int.
 */
unsigned int cometa_signing_key_from_extended_bytes(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key);

/**
 * \brief Import a normal seed key from validated borrowed ASCII hexadecimal.
 * \param[in] data Exactly 64 hex digits, borrowed until return.
 * \param[in] size Digit count, excluding any terminator.
 * \param[out] key Initialized to NULL; receives one owned reference on success.
 * \returns A cardano-c status converted to unsigned int.
 */
unsigned int cometa_signing_key_from_normal_hex(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key);

/**
 * \brief Import an extended key from validated borrowed ASCII hexadecimal.
 * \param[in] data Exactly 128 hex digits, borrowed until return.
 * \param[in] size Digit count, excluding any terminator.
 * \param[out] key Initialized to NULL; receives one owned reference on success.
 * \returns A cardano-c status converted to unsigned int.
 */
unsigned int cometa_signing_key_from_extended_hex(const unsigned char* data, size_t size, cardano_ed25519_private_key_t** key);

/**
 * \brief Deep-copy secret storage into one independent owned key.
 * \param[in] source Live borrowed key, serialized by the Haskell key lock.
 * \param[out] copy Initialized to NULL; receives one owned reference on success.
 * \returns A cardano-c status converted to unsigned int.
 */
unsigned int cometa_signing_key_clone(const cardano_ed25519_private_key_t* source, cardano_ed25519_private_key_t** copy);

/**
 * \brief Consume one key reference; final release wipes native key storage.
 * \param[in,out] key Initialized local owned slot; NULL is tolerated.
 * \note A released alias must not be reused if native unref leaves it non-NULL.
 */
void cometa_signing_key_unref(cardano_ed25519_private_key_t** key);

/**
 * \brief Borrow raw secret storage only while holding the key lock.
 * \param[in] key Live borrowed key.
 * \returns Borrowed secret bytes; never release or mutate them.
 */
const unsigned char* cometa_signing_key_data(const cardano_ed25519_private_key_t* key);

/**
 * \brief Read the secret byte length without exporting secret data.
 * \param[in] key Live borrowed key.
 * \returns The native key length, zero for NULL.
 */
size_t cometa_signing_key_size(const cardano_ed25519_private_key_t* key);

/**
 * \brief Derive public bytes without transferring a native public-key object.
 * \param[in] key Live borrowed key, held under the key lock until return.
 * \param[out] output Caller-owned 32-byte buffer, valid until return.
 * \returns A cardano-c status converted to unsigned int; output is valid only on success.
 */
unsigned int cometa_signing_key_public_key(const cardano_ed25519_private_key_t* key, unsigned char* output);

/**
 * \brief Sign borrowed message bytes; release temporary native signature on every path.
 * \param[in] key Live borrowed key, held under the key lock until return.
 * \param[in] message Message bytes; NULL is permitted only for an empty message.
 * \param[in] size Message byte length.
 * \param[out] output Caller-owned 64-byte buffer, valid until return.
 * \returns A cardano-c status converted to unsigned int; output is valid only on success.
 */
unsigned int cometa_signing_key_sign(const cardano_ed25519_private_key_t* key, const unsigned char* message, size_t size, unsigned char* output);

#ifdef __cplusplus
}
#endif

#endif /* BIGLUP_LABS_INCLUDE_COMETA_SIGNING_KEY_H */
