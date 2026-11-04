/**
 * \file cometa_bip39.c
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

/* INCLUDES ******************************************************************/

#include "cometa_bip39.h"

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_bip39_from_entropy(const unsigned char* entropy, size_t size, const char** words, size_t* count)
{
  return (unsigned int)cardano_bip39_entropy_to_mnemonic_words(entropy, size, words, count);
}

unsigned int
cometa_bip39_to_entropy(const char** words, size_t count, unsigned char* entropy, size_t capacity, size_t* size)
{
  return (unsigned int)cardano_bip39_mnemonic_words_to_entropy(words, count, entropy, capacity, size);
}
