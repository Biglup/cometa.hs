/**
 * \file cometa_key_handler.h
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_KEY_HANDLER_H
#define BIGLUP_LABS_INCLUDE_COMETA_KEY_HANDLER_H

/* INCLUDES ******************************************************************/
#include <cardano/buffer.h>
#include <cardano/key_handlers/software_secure_key_handler.h>
#include <stdint.h>

/* DECLARATIONS **************************************************************/
/** \brief Borrow live handler; copy owned temporary account key to 64 output bytes, releasing it on every exit.
 * \param handler Borrowed handler, valid through return.
 * \param purpose Unencoded purpose below 2^31.
 * \param coin Unencoded coin type below 2^31.
 * \param account Unencoded account below 2^31.
 * \param output Caller-owned 64-byte destination, valid through return.
 * \return Native status; output valid only on success.
 */
unsigned int cometa_handler_account(cardano_secure_key_handler_t* handler, uint32_t purpose, uint32_t coin, uint32_t account, unsigned char* output);
/** \brief Borrow live handler; copy owned temporary Ed25519 public key to 32 bytes, releasing it on every exit.
 * \param handler Borrowed handler, valid through return.
 * \param output Caller-owned 32-byte destination, valid through return.
 * \return Native status; output valid only on success.
 */
unsigned int cometa_handler_public(cardano_secure_key_handler_t* handler, unsigned char* output);
#endif
