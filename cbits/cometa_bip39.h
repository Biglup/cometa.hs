/**
 * \file cometa_bip39.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_BIP39_H
#define BIGLUP_LABS_INCLUDE_COMETA_BIP39_H

/* INCLUDES ******************************************************************/

#include <cardano/bip39.h>

/* DECLARATIONS **************************************************************/

#ifdef __cplusplus
extern "C" {
#endif

/**
 * \brief Convert borrowed entropy to borrowed static English words.
 * \param[in] entropy Borrowed bytes, valid until return.
 * \param[in] size Validated byte count: 16, 20, 24, 28 or 32.
 * \param[out] words Caller-owned array of 24 slots; returned strings must not be freed.
 * \param[out] count Number of words on success.
 * \return Native status converted to unsigned int; outputs valid only on success.
 */
unsigned int cometa_bip39_from_entropy(const unsigned char* entropy, size_t size, const char** words, size_t* count);

/**
 * \brief Convert borrowed words to caller-owned entropy; no ownership transfer.
 * \param[in] words Borrowed NUL-terminated words, valid until return.
 * \param[in] count Validated word count: 12, 15, 18, 21 or 24.
 * \param[out] entropy Caller-owned scratch buffer; wipe even on checksum failure.
 * \param[in] capacity Entropy buffer byte capacity, at least 32.
 * \param[out] size Entropy byte count; output may be written before failure.
 * \return Native status converted to unsigned int; outputs valid only on success.
 */
unsigned int cometa_bip39_to_entropy(const char** words, size_t count, unsigned char* entropy, size_t capacity, size_t* size);

#ifdef __cplusplus
}
#endif

#endif /* BIGLUP_LABS_INCLUDE_COMETA_BIP39_H */
