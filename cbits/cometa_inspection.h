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
 * \param operation 0 transaction, 1 subtransaction, 2 body, 3 subtransaction body;
 * 4 value, 5 script, 6 credential, 7 certificate, 8 proposal, 9 pool parameters,
 * 10 protocol update, 11 Plutus data, 12 output, 13 witnesses, 14 UTxO,
 * 15 DRep, 16 action id, 17 anchor, 18 voting procedures, 19 governance action,
 * 20 metadatum, 21 metadata, 22 auxiliary data, 23 input, 24 datum, 25 redeemer;
 * 26 execution units, 27 protocol version, 28 unit interval, 29 relay,
 * 30 pool metadata, 31 constitution, 32 voter, 33 voting procedure,
 * 34 verification witness, 35 bootstrap witness;
 * 36 cost model, 37 cost models, 38 execution prices, 39 pool thresholds,
 * 40 DRep thresholds, 41 legacy proposed updates, 42 legacy update proposal,
 * 43 balance interval, 44 account intervals, 45 direct deposits, 46 required guards;
 * 47 asset name, 48 BLAKE2b digest, 49 BLS key, 50 committee members,
 * 51 withdrawals, 52 digests, 53 guards, 54 subtransactions,
 * 55 assets object, 56 asset policy entries, 57 policy assets object,
 * 58 policy asset entries.
 * \param input Borrowed complete CBOR bytes, valid through return.
 * \param size Byte count of input.
 * \param output Transferred JSON byte buffer on success, NULL on failure.
 * \return Native status; every reader, parsed object and writer is released.
 */
unsigned int cometa_inspection_compute(unsigned int operation, const unsigned char* input, size_t size, cardano_buffer_t** output);
#endif
