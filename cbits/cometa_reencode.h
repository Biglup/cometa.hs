/**
 * \file cometa_reencode.h
 *
 * \author angel.castillo
 * \date Nov 09, 2026
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
#ifndef COMETA_REENCODE_H
#define COMETA_REENCODE_H
#include <cardano/cardano.h>

/** \brief Re-encode one complete native schema with fresh scoped owners.
 * \param kind 0 native script, 1 native-script list, 2 transaction, 3 intent.
 * \param bytes Borrowed input bytes, valid through return.
 * \param size Input byte count.
 * \param output Transferred owned output buffer on success, null on failure.
 * \return Native status; all parsed owners and writers are released.
 */
unsigned int cometa_reencode(unsigned int kind, const unsigned char* bytes, size_t size, cardano_buffer_t** output);
#endif
