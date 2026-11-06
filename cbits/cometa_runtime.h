/**
 * \file cometa_runtime.h
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

#ifndef BIGLUP_LABS_COMETA_RUNTIME_H
#define BIGLUP_LABS_COMETA_RUNTIME_H

/* INCLUDES ******************************************************************/
#include <cardano/buffer.h>
#include <cardano/object.h>
#include <HsFFI.h>
#include <stddef.h>
#include <stdint.h>

/* TYPES *********************************************************************/
typedef struct cometa_runtime_t cometa_runtime_t;

/** \brief Borrow request storage and transfer one owned reply on success; exceptions never cross C.
 * \param state Adopted Haskell stable pointer.
 * \param operation Private family operation identifier.
 * \param request Borrowed request bytes through return.
 * \param size Request byte length.
 * \param reply Initialized-null output; owned by caller on success.
 * \param error Borrowed diagnostic storage.
 * \param capacity Diagnostic byte capacity including terminator.
 * \return Native status. Failure leaves reply null; original Haskell failure is saved separately.
 */
typedef unsigned int (*cometa_runtime_callback_t)(HsStablePtr state, uint32_t operation, const unsigned char* request, size_t size, cardano_buffer_t** reply, char* error, size_t capacity);

/* DECLARATIONS **************************************************************/
/** \brief Success adopts both runtime handles; failure adopts neither and initializes output null.
 * \param state Haskell callback state.
 * \param callback Rooted callback trampoline.
 * \param output Owned context output on success.
 * \return Native status.
 */
unsigned int cometa_runtime_new(HsStablePtr state, cometa_runtime_callback_t callback, cometa_runtime_t** output);
/** \brief Retain one context reference; caller serializes reference transitions. */
void cometa_runtime_ref(cometa_runtime_t* context);
/** \brief Consume one context reference; final destruction releases adopted Haskell handles. */
void cometa_runtime_release(cometa_runtime_t* context);
/** \brief Borrow the native object base for implementation context adoption; retain before transfer. */
cardano_object_t* cometa_runtime_object(cometa_runtime_t* context);
/** \brief Synchronous callback dispatch. Input borrowed; reply transfers to caller on success. */
unsigned int cometa_runtime_dispatch(cometa_runtime_t* context, uint32_t operation, const unsigned char* request, size_t size, cardano_buffer_t** reply, char* error, size_t capacity);
/** \brief Copy borrowed bytes into a newly owned buffer; initialize output null. */
unsigned int cometa_runtime_buffer_new(const unsigned char* bytes, size_t size, cardano_buffer_t** output);
/** \brief Consume and null an owned buffer slot. */
void cometa_runtime_buffer_release(cardano_buffer_t** buffer);
/** \brief Borrow buffer storage until its owner is released. */
const unsigned char* cometa_runtime_buffer_data(const cardano_buffer_t* buffer);
/** \brief Observe buffer size through an explicit size_t ABI. */
size_t cometa_runtime_buffer_size(const cardano_buffer_t* buffer);
/** \brief Test instrumentation: number of contexts still rooting Haskell registrations. */
size_t cometa_runtime_live_contexts(void);
#endif
