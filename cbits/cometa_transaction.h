/**
 * \file cometa_transaction.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_TRANSACTION_H
#define BIGLUP_LABS_INCLUDE_COMETA_TRANSACTION_H

/* INCLUDES ******************************************************************/

#include <stddef.h>
#include <stdint.h>

/* TYPES *********************************************************************/

/** \brief Owned immutable byte snapshots; contains no Haskell handles. */
typedef struct cometa_transaction_snapshot_t cometa_transaction_snapshot_t;

/* FUNCTIONS *****************************************************************/

/**
 * \brief Validate one complete transaction and snapshot its original encoding.
 * \param[in] data Borrowed complete transaction CBOR, valid until return.
 * \param[in] size Input length in bytes.
 * \param[out] snapshot One owned result on success; NULL on failure.
 * \returns A cardano-c status through an explicit unsigned ABI.
 * \note Rejects trailing bytes. Original full/body/witness encodings are copied.
 */
unsigned int cometa_transaction_decode(const unsigned char* data, size_t size, cometa_transaction_snapshot_t** snapshot);

/**
 * \brief Deep-clone a decoded transaction, change its fee and strip signatures.
 * \param[in] data Borrowed complete transaction CBOR, valid until return.
 * \param[in] size Input length in bytes.
 * \param[in] fee New fee in lovelace.
 * \param[out] snapshot One owned result on success; NULL on failure.
 * \returns A cardano-c status through an explicit unsigned ABI.
 * \note Clears only the body's encoding cache and outer vkey/bootstrap witnesses.
 * Scripts, datums, redeemers and auxiliary data remain on the independent clone.
 * Callers implement same-fee no-op preservation before invoking this function.
 */
unsigned int cometa_transaction_set_fee(const unsigned char* data, size_t size, uint64_t fee, cometa_transaction_snapshot_t** snapshot);

/**
 * \brief Destroy one snapshot and clear its slot. NULL slots are tolerated.
 * \param[in,out] snapshot The local ownership obligation to consume.
 */
void cometa_transaction_snapshot_free(cometa_transaction_snapshot_t** snapshot);

/**
 * \brief Borrow a snapshot byte span until its owner is destroyed.
 * \param[in] snapshot Live immutable snapshot.
 * \param[in] field Private adapter ABI: 0 full CBOR, 1 body CBOR, 2 body hash, 3 witness CBOR.
 * \param[out] size Number of bytes; zero for an invalid field or snapshot.
 * \returns Borrowed bytes, or NULL for an invalid field or snapshot. Never free.
 */
const unsigned char* cometa_transaction_snapshot_bytes(const cometa_transaction_snapshot_t* snapshot, unsigned int field, size_t* size);

/**
 * \brief Read the snapshotted fee in lovelace.
 * \param[in] snapshot Live immutable snapshot; NULL yields zero.
 * \returns Exact unsigned 64-bit fee.
 */
uint64_t cometa_transaction_snapshot_fee(const cometa_transaction_snapshot_t* snapshot);

#endif /* BIGLUP_LABS_INCLUDE_COMETA_TRANSACTION_H */
