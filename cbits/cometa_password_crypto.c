/**
 * \file cometa_password_crypto.c
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

#include "cometa_password_crypto.h"

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_pbkdf2(const unsigned char* password, size_t password_size, const unsigned char* salt, size_t salt_size, uint32_t iterations, unsigned char* output, size_t output_size)
{
  return (unsigned int)cardano_crypto_pbkdf2_hmac_sha512(password, password_size, salt, salt_size, iterations, output, output_size);
}

unsigned int
cometa_emip3_encrypt(const unsigned char* data, size_t size, const unsigned char* password, size_t password_size, cardano_buffer_t** output)
{
  return (unsigned int)cardano_crypto_emip3_encrypt(data, size, password, password_size, output);
}

unsigned int
cometa_emip3_decrypt(const unsigned char* data, size_t size, const unsigned char* password, size_t password_size, cardano_buffer_t** output)
{
  return (unsigned int)cardano_crypto_emip3_decrypt(data, size, password, password_size, output);
}

void
cometa_password_buffer_release(cardano_buffer_t** output)
{
  if ((output != NULL) && (*output != NULL))
  {
    cardano_buffer_memzero(*output);
    cardano_buffer_unref(output);
    *output = NULL;
  }
}
