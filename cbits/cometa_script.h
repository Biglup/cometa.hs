/**
 * \file cometa_script.h
 *
 * \author angel.castillo
 * \date   Nov 04, 2026
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_SCRIPT_H
#define BIGLUP_LABS_INCLUDE_COMETA_SCRIPT_H

/* INCLUDES ******************************************************************/

#include <cardano/buffer.h>
#include <stddef.h>

/* DECLARATIONS **************************************************************/

/**
 * \brief Applies marshaled Plutus data parameters using the native UPLC VM.
 *
 * \param[in] script Borrowed nonempty single-CBOR-wrapped Flat program bytes.
 * \param[in] script_size Script byte count.
 * \param[in] params Borrowed CBOR array of Plutus data, valid through return.
 * \param[in] params_size Parameter encoding byte count.
 * \param[out] output Initialized to NULL; owns any resulting buffer reference even on failure.
 * \param[out] error Optional caller-owned diagnostic storage, copied before releasing readers.
 * \param[in] error_size Diagnostic capacity including terminator; zero disables copying.
 *
 * \return A cardano-c status converted to unsigned int. All temporary readers,
 * lists and VM arenas are released synchronously before return. No callbacks run.
 */
unsigned int cometa_script_apply_params(
  const unsigned char* script,
  size_t               script_size,
  const unsigned char* params,
  size_t               params_size,
  cardano_buffer_t**   output,
  char*                error,
  size_t               error_size);

#endif // BIGLUP_LABS_INCLUDE_COMETA_SCRIPT_H
