/**
 * \file cometa_native_evaluation.h
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

#ifndef BIGLUP_LABS_COMETA_NATIVE_EVALUATION_H
#define BIGLUP_LABS_COMETA_NATIVE_EVALUATION_H

/* INCLUDES ******************************************************************/

#include <cardano/cardano.h>
#include <stddef.h>
#include <stdint.h>

/* DECLARATIONS **************************************************************/

/**
 * \brief Evaluate with operation-owned resources and borrowed CBOR inputs.
 * \param[in] zero_time Unix milliseconds at zero_slot.
 * \param[in] zero_slot Schedule reference slot.
 * \param[in] slot_length Positive slot duration in milliseconds.
 * \param[in] protocol_major Protocol major version selecting builtin semantics.
 * \param[in] is_sub Zero selects top-level; nonzero selects sub_index.
 * \param[in] sub_index Sub-transaction position when selected.
 * \param[in] models Borrowed cost-model map CBOR until return.
 * \param[in] models_size Complete cost-model byte count.
 * \param[in] transaction Borrowed transaction CBOR until return.
 * \param[in] transaction_size Complete transaction byte count.
 * \param[in] utxos Borrowed resolved UTxO array CBOR until return.
 * \param[in] utxos_size Complete UTxO array byte count.
 * \param[out] output Owned redeemer CBOR on success; NULL on failure.
 * \param[out] diagnostic Owned copied diagnostic on failure when allocation succeeds.
 * \return Native status. Both output slots initialize NULL; all parsed objects
 * and evaluator references are released before return, including partial errors.
 */
unsigned int cometa_native_evaluation_run(uint64_t zero_time, uint64_t zero_slot, uint64_t slot_length, uint64_t protocol_major, unsigned int is_sub, uint64_t sub_index, const unsigned char* models, size_t models_size, const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, cardano_buffer_t** output, cardano_buffer_t** diagnostic);

#endif
