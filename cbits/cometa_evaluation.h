/**
 * \file cometa_evaluation.h
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

#ifndef BIGLUP_LABS_COMETA_EVALUATION_H
#define BIGLUP_LABS_COMETA_EVALUATION_H
#include "cometa_runtime.h"
#include <cardano/transaction_builder/evaluation/tx_evaluator.h>
/* New evaluator adopts one independently retained runtime context on success.
 * Failure initializes output null and leaves the caller's context owner intact. */
unsigned int cometa_evaluation_new(cometa_runtime_t* runtime, cardano_tx_evaluator_t** output);
/* Parse borrowed inputs, dispatch the actual native evaluator count times, then
 * transfer one serialized redeemer result. All partial state is always released. */
unsigned int cometa_evaluation_run(cometa_runtime_t* runtime, const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, uint32_t count, cardano_buffer_t** output);
/* Same operation through cardano_tx_evaluator_from_provider. The provider's
 * construction owner is released before dispatch, proving retained lifetime. */
unsigned int cometa_evaluation_run_provider(cometa_runtime_t* runtime, const unsigned char* transaction, size_t transaction_size, const unsigned char* utxos, size_t utxos_size, uint32_t count, cardano_buffer_t** output);
#endif
