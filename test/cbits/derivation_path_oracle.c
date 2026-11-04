/**
 * \file derivation_path_oracle.c
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

#include <cardano/cardano.h>
#include <string.h>

/* DEFINITIONS ***************************************************************/

/**
 * \brief Read the nine pinned CIP-1852 constants into caller-owned storage.
 * \param[out] values Nine uint32_t slots, borrowed until return.
 */
void
cometa_test_path_constants(uint32_t* values)
{
  const uint32_t constants[] = {
    CARDANO_CIP_1852_COIN_TYPE, CARDANO_CIP_1852_PURPOSE_STANDARD, CARDANO_CIP_1852_PURPOSE_MULTI_SIG, CARDANO_CIP_1852_ROLE_EXTERNAL, CARDANO_CIP_1852_ROLE_INTERNAL, CARDANO_CIP_1852_ROLE_STAKING, CARDANO_CIP_1852_ROLE_DREP, CARDANO_CIP_1852_ROLE_CC_COLD, CARDANO_CIP_1852_ROLE_CC_HOT
  };

  memcpy(values, constants, sizeof(constants));
}

/**
 * \brief Derive a public key using the software-handler path encoding rules.
 * \param[in] bytes Borrowed 96-byte fixture root, valid until return.
 * \param[in] components Five unencoded uint64_t path components.
 * \param[in] account_only Derive only the three-component account prefix.
 * \param[out] output Caller-owned 64-byte public key, valid only on success.
 * \return Native status. All temporary native references are released.
 */
unsigned int
cometa_test_path_public(const unsigned char* bytes, const uint64_t* components, int account_only, unsigned char* output)
{
  const cardano_derivation_path_t         path      = { components[0], components[1], components[2], components[3], components[4] };
  const cardano_account_derivation_path_t account   = { path.purpose, path.coin_type, path.account };
  const uint32_t                          indices[] = {
    cardano_bip32_harden((uint32_t)account.purpose),
    cardano_bip32_harden((uint32_t)account.coin_type),
    cardano_bip32_harden((uint32_t)account.account),
    (uint32_t)path.role,
    (uint32_t)path.index
  };
  cardano_bip32_private_key_t* root       = NULL;
  cardano_bip32_private_key_t* child      = NULL;
  cardano_bip32_public_key_t*  public_key = NULL;

  cardano_error_t status = cardano_bip32_private_key_from_bytes(bytes, 96U, &root);

  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  status = cardano_bip32_private_key_derive(root, indices, account_only ? 3U : 5U, &child);

  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  status = cardano_bip32_private_key_get_public_key(child, &public_key);

  if (status == CARDANO_SUCCESS)
  {
    memcpy(output, cardano_bip32_public_key_get_data(public_key), 64U);
  }

cleanup:
  cardano_bip32_public_key_unref(&public_key);
  cardano_bip32_private_key_unref(&child);
  cardano_bip32_private_key_unref(&root);

  return (unsigned int)status;
}

/**
 * \brief Supply a deterministic test-only encryption password.
 * \param[out] buffer Borrowed password buffer.
 * \param[in] size Buffer byte capacity.
 * \return One byte written, or -1 if the buffer is too small.
 */
static int32_t
fixture_password(byte_t* buffer, size_t size)
{
  if (size < 1U)
  {
    return -1;
  }

  buffer[0] = 'x';
  return 1;
}

/**
 * \brief Exercise actual software-handler consumption of an account struct.
 * \param[in] entropy Borrowed 32-byte deterministic fixture entropy.
 * \param[in] components Three unencoded uint64_t account components.
 * \param[out] output Caller-owned 64-byte public key, valid on success.
 * \return Native status. Handler and public-key references are always released.
 */
unsigned int
cometa_test_handler_account(const unsigned char* entropy, const uint64_t* components, unsigned char* output)
{
  const cardano_account_derivation_path_t path    = { components[0], components[1], components[2] };
  cardano_secure_key_handler_t*           handler = NULL;
  cardano_bip32_public_key_t*             key     = NULL;

  cardano_error_t status = cardano_software_secure_key_handler_new(entropy, 32U, (const byte_t*)"x", 1U, fixture_password, &handler);

  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  status = cardano_secure_key_handler_bip32_get_extended_account_public_key(handler, path, &key);

  if (status == CARDANO_SUCCESS)
  {
    memcpy(output, cardano_bip32_public_key_get_data(key), 64U);
  }

cleanup:
  cardano_bip32_public_key_unref(&key);
  cardano_secure_key_handler_unref(&handler);

  return (unsigned int)status;
}
