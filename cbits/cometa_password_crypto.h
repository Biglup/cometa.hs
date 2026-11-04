/**
 * \file cometa_password_crypto.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_PASSWORD_CRYPTO_H
#define BIGLUP_LABS_INCLUDE_COMETA_PASSWORD_CRYPTO_H

/* INCLUDES ******************************************************************/

#include <cardano/buffer.h>
#include <cardano/crypto/emip3.h>
#include <cardano/crypto/pbkdf2.h>

/* DECLARATIONS **************************************************************/

#ifdef __cplusplus
extern "C" {
#endif

/**
 * \brief Derive into caller-owned scratch storage, with unsigned status ABI.
 * \param[in] password Borrowed password bytes; may be empty.
 * \param[in] password_size Password byte count.
 * \param[in] salt Borrowed nonempty salt.
 * \param[in] salt_size Salt byte count.
 * \param[in] iterations Validated positive iteration count through UINT32_MAX.
 * \param[out] output Caller-owned scratch; wipe on every exit.
 * \param[in] output_size Validated positive output byte count.
 * \return Native status converted to unsigned int.
 */
unsigned int cometa_pbkdf2(const unsigned char* password, size_t password_size, const unsigned char* salt, size_t salt_size, uint32_t iterations, unsigned char* output, size_t output_size);

/**
 * \brief Encrypt borrowed plaintext into one owned ciphertext reference.
 * \param[in] data Borrowed non-NULL plaintext; may be empty.
 * \param[in] size Plaintext byte count; size plus 60 must not overflow.
 * \param[in] password Borrowed password bytes; may be empty.
 * \param[in] password_size Password byte count.
 * \param[out] output Initialized null slot; owns one reference on success.
 * \return Native status converted to unsigned int.
 */
unsigned int cometa_emip3_encrypt(const unsigned char* data, size_t size, const unsigned char* password, size_t password_size, cardano_buffer_t** output);

/**
 * \brief Decrypt borrowed ciphertext into one owned plaintext reference.
 * \param[in] data Borrowed envelope of at least 60 bytes.
 * \param[in] size Envelope byte count.
 * \param[in] password Borrowed password bytes; may be empty.
 * \param[in] password_size Password byte count.
 * \param[out] output Initialized null slot; wipe before releasing success output.
 * \return Native status converted to unsigned int. Authentication failure zeros
 * the output before native release; see the pinned libsodium audit.
 */
unsigned int cometa_emip3_decrypt(const unsigned char* data, size_t size, const unsigned char* password, size_t password_size, cardano_buffer_t** output);

/**
 * \brief Wipe and release the locally owned reference, then clear its slot.
 * \param[in,out] output Local initialized slot; no borrowed alias may escape.
 */
void cometa_password_buffer_release(cardano_buffer_t** output);

#ifdef __cplusplus
}
#endif

#endif /* BIGLUP_LABS_INCLUDE_COMETA_PASSWORD_CRYPTO_H */
