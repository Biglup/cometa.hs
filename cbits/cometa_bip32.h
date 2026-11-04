/**
 * \file cometa_bip32.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_BIP32_H
#define BIGLUP_LABS_INCLUDE_COMETA_BIP32_H

/* INCLUDES ******************************************************************/

#include <cardano/crypto/bip32_private_key.h>
#include <stddef.h>
#include <stdint.h>

/* DECLARATIONS **************************************************************/

#ifdef __cplusplus
extern "C" {
#endif

/**
 * \brief Import borrowed 96-byte secret data into one owned output.
 * \param[in] data Borrowed input; valid until return.
 * \param[in] size Byte length, exactly 96.
 * \param[out] key Initialized to NULL; receives one owned reference on success.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_from_bytes(const unsigned char* data, size_t size, cardano_bip32_private_key_t** key);

/**
 * \brief Import borrowed validated 192-digit ASCII hex into one owned output.
 * \param[in] data Borrowed input; valid until return.
 * \param[in] size Digit count, exactly 192; no terminator.
 * \param[out] key Initialized to NULL; receives one owned reference on success.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_from_hex(const unsigned char* data, size_t size, cardano_bip32_private_key_t** key);

/**
 * \brief Derive one owned root; password and entropy are borrowed until return.
 * \param[in] password Borrowed input; valid until return.
 * \param[in] password_size Password byte count; zero is permitted.
 * \param[in] entropy Borrowed nonempty entropy bytes, valid until return.
 * \param[in] entropy_size Entropy byte count.
 * \param[out] key Initialized to NULL; receives one owned reference on success.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_from_entropy(const unsigned char* password, size_t password_size, const unsigned char* entropy, size_t entropy_size, cardano_bip32_private_key_t** key);

/**
 * \brief Clone a locked borrowed source into independent owned storage.
 * \param[in] source Borrowed input; valid until return.
 * \param[out] key Initialized to NULL; receives one independent owned reference.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_clone(const cardano_bip32_private_key_t* source, cardano_bip32_private_key_t** key);

/**
 * \brief Derive an owned key from locked source and borrowed nonempty path.
 * \param[in] source Borrowed input; valid until return.
 * \param[in] indices Borrowed encoded indices, valid until return.
 * \param[in] count Number of indices; must be positive.
 * \param[out] key Initialized to NULL; receives one independent owned reference.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_derive(const cardano_bip32_private_key_t* source, const uint32_t* indices, size_t count, cardano_bip32_private_key_t** key);

/**
 * \brief Copy locked source into one owned extended Ed25519 key.
 * \param[in] source Borrowed input; valid until return.
 * \param[out] key Initialized to NULL; receives one independent owned signing key.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_to_signing_key(const cardano_bip32_private_key_t* source, cardano_ed25519_private_key_t** key);

/**
 * \brief Consume one reference; callers clear their local slot even for retained aliases.
 * \param[in,out] key Owned local slot; NULL is tolerated.
 * \returns No result.
 */
void cometa_bip32_unref(cardano_bip32_private_key_t** key);

/**
 * \brief Borrow secret storage only while holding the key lock.
 * \param[in] key Live locked borrowed key.
 * \returns Borrowed bytes; never release or mutate.
 */
const unsigned char* cometa_bip32_data(const cardano_bip32_private_key_t* key);

/**
 * \brief Read fixed length while holding the key lock.
 * \param[in] key Live locked borrowed key.
 * \returns Native byte length.
 */
size_t cometa_bip32_size(const cardano_bip32_private_key_t* key);

/**
 * \brief Copy 64 public bytes to caller buffer; release temporary public owner on every path.
 * \param[in] key Borrowed input; valid until return.
 * \param[out] output Caller-owned 64-byte buffer, valid until return.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_public_key(const cardano_bip32_private_key_t* key, unsigned char* output);

/**
 * \brief Borrow 64 input bytes and nonempty path; write 64 output bytes only on success.
 * \param[in] bytes Borrowed input; valid until return.
 * \param[in] indices Borrowed soft indices, valid until return.
 * \param[in] count Number of indices; must be positive.
 * \param[out] output Caller-owned 64-byte buffer, valid until return.
 * \returns cardano-c status as unsigned int; outputs are valid only on success.
 */
unsigned int cometa_bip32_derive_public(const unsigned char* bytes, const uint32_t* indices, size_t count, unsigned char* output);

#ifdef __cplusplus
}
#endif

#endif /* BIGLUP_LABS_INCLUDE_COMETA_BIP32_H */
