/**
 * \file certificates_oracle.c
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

/* INCLUDES ******************************************************************/

#include <cardano/cardano.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/** \brief Reconstructs stake registration; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_stake_registration(cardano_stake_registration_cert_t* source, cardano_stake_registration_cert_t** output)
{
  cardano_credential_t* credential = cardano_stake_registration_cert_get_credential(source);
  cardano_error_t       result     = cardano_stake_registration_cert_new(credential, output);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs stake deregistration; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_stake_deregistration(cardano_stake_deregistration_cert_t* source, cardano_stake_deregistration_cert_t** output)
{
  cardano_credential_t* credential = cardano_stake_deregistration_cert_get_credential(source);
  cardano_error_t       result     = cardano_stake_deregistration_cert_new(credential, output);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs stake delegation; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_stake_delegation(cardano_stake_delegation_cert_t* source, cardano_stake_delegation_cert_t** output)
{
  cardano_credential_t*   credential    = cardano_stake_delegation_cert_get_credential(source);
  cardano_blake2b_hash_t* pool_key_hash = cardano_stake_delegation_cert_get_pool_key_hash(source);
  cardano_error_t         result        = cardano_stake_delegation_cert_new(credential, pool_key_hash, output);
  cardano_blake2b_hash_unref(&pool_key_hash);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs pool retirement; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_pool_retirement(cardano_pool_retirement_cert_t* source, cardano_pool_retirement_cert_t** output)
{
  cardano_blake2b_hash_t* pool_key_hash = cardano_pool_retirement_cert_get_pool_key_hash(source);
  uint64_t                epoch         = cardano_pool_retirement_cert_get_epoch(source);
  cardano_error_t         result        = cardano_pool_retirement_cert_new(pool_key_hash, epoch, output);
  cardano_blake2b_hash_unref(&pool_key_hash);
  return result;
}

/** \brief Reconstructs genesis key delegation; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_genesis_key_delegation(cardano_genesis_key_delegation_cert_t* source, cardano_genesis_key_delegation_cert_t** output)
{
  cardano_blake2b_hash_t* genesis_hash          = cardano_genesis_key_delegation_cert_get_genesis_hash(source);
  cardano_blake2b_hash_t* genesis_delegate_hash = cardano_genesis_key_delegation_cert_get_genesis_delegate_hash(source);
  cardano_blake2b_hash_t* vrf_key_hash          = cardano_genesis_key_delegation_cert_get_vrf_key_hash(source);
  cardano_error_t         result                = cardano_genesis_key_delegation_cert_new(genesis_hash, genesis_delegate_hash, vrf_key_hash, output);
  cardano_blake2b_hash_unref(&vrf_key_hash);
  cardano_blake2b_hash_unref(&genesis_delegate_hash);
  cardano_blake2b_hash_unref(&genesis_hash);
  return result;
}

/** \brief Reconstructs registration; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_registration(cardano_registration_cert_t* source, cardano_registration_cert_t** output)
{
  cardano_credential_t* credential = cardano_registration_cert_get_stake_credential(source);
  uint64_t              deposit    = cardano_registration_cert_get_deposit(source);
  cardano_error_t       result     = cardano_registration_cert_new(credential, deposit, output);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs unregistration; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_unregistration(cardano_unregistration_cert_t* source, cardano_unregistration_cert_t** output)
{
  cardano_credential_t* credential = cardano_unregistration_cert_get_credential(source);
  uint64_t              deposit    = cardano_unregistration_cert_get_deposit(source);
  cardano_error_t       result     = cardano_unregistration_cert_new(credential, deposit, output);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs vote delegation; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_vote_delegation(cardano_vote_delegation_cert_t* source, cardano_vote_delegation_cert_t** output)
{
  cardano_credential_t* credential = cardano_vote_delegation_cert_get_credential(source);
  cardano_drep_t*       drep       = cardano_vote_delegation_cert_get_drep(source);
  cardano_error_t       result     = cardano_vote_delegation_cert_new(credential, drep, output);
  cardano_drep_unref(&drep);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs stake vote delegation; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_stake_vote_delegation(cardano_stake_vote_delegation_cert_t* source, cardano_stake_vote_delegation_cert_t** output)
{
  cardano_credential_t*   credential    = cardano_stake_vote_delegation_cert_get_credential(source);
  cardano_blake2b_hash_t* pool_key_hash = cardano_stake_vote_delegation_cert_get_pool_key_hash(source);
  cardano_drep_t*         drep          = cardano_stake_vote_delegation_cert_get_drep(source);
  cardano_error_t         result        = cardano_stake_vote_delegation_cert_new(credential, pool_key_hash, drep, output);
  cardano_drep_unref(&drep);
  cardano_blake2b_hash_unref(&pool_key_hash);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs stake registration delegation; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_stake_registration_delegation(cardano_stake_registration_delegation_cert_t* source, cardano_stake_registration_delegation_cert_t** output)
{
  cardano_credential_t*   credential    = cardano_stake_registration_delegation_cert_get_credential(source);
  cardano_blake2b_hash_t* pool_key_hash = cardano_stake_registration_delegation_cert_get_pool_key_hash(source);
  uint64_t                deposit       = cardano_stake_registration_delegation_cert_get_deposit(source);
  cardano_error_t         result        = cardano_stake_registration_delegation_cert_new(credential, pool_key_hash, deposit, output);
  cardano_blake2b_hash_unref(&pool_key_hash);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs vote registration delegation; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_vote_registration_delegation(cardano_vote_registration_delegation_cert_t* source, cardano_vote_registration_delegation_cert_t** output)
{
  cardano_credential_t* credential = cardano_vote_registration_delegation_cert_get_credential(source);
  uint64_t              deposit    = cardano_vote_registration_delegation_cert_get_deposit(source);
  cardano_drep_t*       drep       = cardano_vote_registration_delegation_cert_get_drep(source);
  cardano_error_t       result     = cardano_vote_registration_delegation_cert_new(credential, deposit, drep, output);
  cardano_drep_unref(&drep);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs stake vote registration delegation; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_stake_vote_registration_delegation(cardano_stake_vote_registration_delegation_cert_t* source, cardano_stake_vote_registration_delegation_cert_t** output)
{
  cardano_credential_t*   credential    = cardano_stake_vote_registration_delegation_cert_get_credential(source);
  uint64_t                deposit       = cardano_stake_vote_registration_delegation_cert_get_deposit(source);
  cardano_drep_t*         drep          = cardano_stake_vote_registration_delegation_cert_get_drep(source);
  cardano_blake2b_hash_t* pool_key_hash = cardano_stake_vote_registration_delegation_cert_get_pool_key_hash(source);
  cardano_error_t         result        = cardano_stake_vote_registration_delegation_cert_new(credential, deposit, drep, pool_key_hash, output);
  cardano_blake2b_hash_unref(&pool_key_hash);
  cardano_drep_unref(&drep);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs resign committee cold; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_resign_committee_cold(cardano_resign_committee_cold_cert_t* source, cardano_resign_committee_cold_cert_t** output)
{
  cardano_credential_t* credential = cardano_resign_committee_cold_cert_get_credential(source);
  cardano_anchor_t*     anchor     = cardano_resign_committee_cold_cert_get_anchor(source);
  cardano_error_t       result     = cardano_resign_committee_cold_cert_new(credential, anchor, output);
  cardano_anchor_unref(&anchor);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs register drep; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_register_drep(cardano_register_drep_cert_t* source, cardano_register_drep_cert_t** output)
{
  cardano_credential_t* credential = cardano_register_drep_cert_get_credential(source);
  uint64_t              deposit    = cardano_register_drep_cert_get_deposit(source);
  cardano_anchor_t*     anchor     = cardano_register_drep_cert_get_anchor(source);
  cardano_error_t       result     = cardano_register_drep_cert_new(credential, deposit, anchor, output);
  cardano_anchor_unref(&anchor);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs unregister drep; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_unregister_drep(cardano_unregister_drep_cert_t* source, cardano_unregister_drep_cert_t** output)
{
  cardano_credential_t* credential = cardano_unregister_drep_cert_get_credential(source);
  uint64_t              deposit    = cardano_unregister_drep_cert_get_deposit(source);
  cardano_error_t       result     = cardano_unregister_drep_cert_new(credential, deposit, output);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs update drep; every pointer getter transfers a retained reference. */
static cardano_error_t
rebuild_update_drep(cardano_update_drep_cert_t* source, cardano_update_drep_cert_t** output)
{
  cardano_credential_t* credential = cardano_update_drep_cert_get_credential(source);
  cardano_anchor_t*     anchor     = cardano_update_drep_cert_get_anchor(source);
  cardano_error_t       result     = cardano_update_drep_cert_new(credential, anchor, output);
  cardano_anchor_unref(&anchor);
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs committee authorization, releasing both retained getters. */
static cardano_error_t
rebuild_auth_committee_hot(cardano_auth_committee_hot_cert_t* source, cardano_auth_committee_hot_cert_t** output)
{
  cardano_credential_t* cold   = NULL;
  cardano_credential_t* hot    = NULL;
  cardano_error_t       result = cardano_auth_committee_hot_cert_get_cold_cred(source, &cold);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_auth_committee_hot_cert_get_hot_cred(source, &hot);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_auth_committee_hot_cert_new(cold, hot, output);
  }
  cardano_credential_unref(&hot);
  cardano_credential_unref(&cold);
  return result;
}

/** \brief Reconstructs a registration envelope around its retained parameter snapshot.
 * Pool parameter fields are independently reconstructed by the pool oracle.
 */
static cardano_error_t
rebuild_pool_registration(cardano_pool_registration_cert_t* source, cardano_pool_registration_cert_t** output)
{
  cardano_pool_params_t* parameters = NULL;
  cardano_error_t        result     = cardano_pool_registration_cert_get_params(source, &parameters);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_pool_registration_cert_new(parameters, output);
  }
  cardano_pool_params_unref(&parameters);
  return result;
}

/** \brief Reconstructs unsigned MIR reward entries through retained indexed getters. */
static cardano_error_t
rebuild_rewards(cardano_mir_to_stake_creds_cert_t* source, cardano_mir_to_stake_creds_cert_t** output)
{
  cardano_mir_cert_pot_type_t pot    = CARDANO_MIR_CERT_POT_TYPE_RESERVE;
  cardano_error_t             result = cardano_mir_to_stake_creds_cert_get_pot(source, &pot);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_mir_to_stake_creds_cert_new(pot, output);
  }
  for (size_t index = 0; result == CARDANO_SUCCESS && index < cardano_mir_to_stake_creds_cert_get_size(source); ++index)
  {
    cardano_credential_t* credential = NULL;
    uint64_t              amount     = 0;
    result                           = cardano_mir_to_stake_creds_cert_get_key_value_at(source, index, &credential, &amount);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_mir_to_stake_creds_cert_insert(*output, credential, amount);
    }
    cardano_credential_unref(&credential);
  }
  return result;
}

/** \brief Reconstructs a pot transfer; out-parameter getters copy scalar values. */
static cardano_error_t
rebuild_pot(cardano_mir_to_pot_cert_t* source, cardano_mir_to_pot_cert_t** output)
{
  cardano_mir_cert_pot_type_t pot    = CARDANO_MIR_CERT_POT_TYPE_RESERVE;
  uint64_t                    amount = 0;
  cardano_error_t             result = cardano_mir_to_pot_cert_get_pot(source, &pot);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_mir_to_pot_cert_get_amount(source, &amount);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_mir_to_pot_cert_new(pot, amount, output);
  }
  return result;
}

/** \brief Reconstructs either MIR alternative, releasing adopted and retained obligations. */
static cardano_error_t
rebuild_mir(cardano_mir_cert_t* source, cardano_mir_cert_t** output)
{
  cardano_mir_cert_type_t kind   = CARDANO_MIR_CERT_TYPE_TO_POT;
  cardano_error_t         result = cardano_mir_cert_get_type(source, &kind);
  if (result != CARDANO_SUCCESS)
  {
    return result;
  }
  if (kind == CARDANO_MIR_CERT_TYPE_TO_POT)
  {
    cardano_mir_to_pot_cert_t* old   = NULL;
    cardano_mir_to_pot_cert_t* fresh = NULL;
    result                           = cardano_mir_cert_as_to_other_pot(source, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_pot(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_mir_cert_new_to_other_pot(fresh, output);
    }
    cardano_mir_to_pot_cert_unref(&fresh);
    cardano_mir_to_pot_cert_unref(&old);
  }
  else
  {
    cardano_mir_to_stake_creds_cert_t* old   = NULL;
    cardano_mir_to_stake_creds_cert_t* fresh = NULL;
    result                                   = cardano_mir_cert_as_to_stake_creds(source, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_rewards(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_mir_cert_new_to_stake_creds(fresh, output);
    }
    cardano_mir_to_stake_creds_cert_unref(&fresh);
    cardano_mir_to_stake_creds_cert_unref(&old);
  }
  return result;
}

/** \brief Reconstructs each certificate subtype from getters and fresh constructors.
 * Wrapper conversions retain subtype objects; both old and fresh obligations
 * are released independently, including failure paths.
 */
static cardano_error_t
rebuild_certificate(cardano_certificate_t* source, cardano_certificate_t** output)
{
  cardano_cert_type_t kind   = CARDANO_CERT_TYPE_STAKE_REGISTRATION;
  cardano_error_t     result = cardano_cert_get_type(source, &kind);
  if (result != CARDANO_SUCCESS)
  {
    return result;
  }
  switch (kind)
  {
    case 0:
    {
      cardano_stake_registration_cert_t* old   = NULL;
      cardano_stake_registration_cert_t* fresh = NULL;
      result                                   = cardano_certificate_to_stake_registration(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_stake_registration(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_stake_registration(fresh, output);
      }
      cardano_stake_registration_cert_unref(&fresh);
      cardano_stake_registration_cert_unref(&old);
      break;
    }
    case 1:
    {
      cardano_stake_deregistration_cert_t* old   = NULL;
      cardano_stake_deregistration_cert_t* fresh = NULL;
      result                                     = cardano_certificate_to_stake_deregistration(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_stake_deregistration(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_stake_deregistration(fresh, output);
      }
      cardano_stake_deregistration_cert_unref(&fresh);
      cardano_stake_deregistration_cert_unref(&old);
      break;
    }
    case 2:
    {
      cardano_stake_delegation_cert_t* old   = NULL;
      cardano_stake_delegation_cert_t* fresh = NULL;
      result                                 = cardano_certificate_to_stake_delegation(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_stake_delegation(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_stake_delegation(fresh, output);
      }
      cardano_stake_delegation_cert_unref(&fresh);
      cardano_stake_delegation_cert_unref(&old);
      break;
    }
    case 3:
    {
      cardano_pool_registration_cert_t* old   = NULL;
      cardano_pool_registration_cert_t* fresh = NULL;
      result                                  = cardano_certificate_to_pool_registration(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_pool_registration(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_pool_registration(fresh, output);
      }
      cardano_pool_registration_cert_unref(&fresh);
      cardano_pool_registration_cert_unref(&old);
      break;
    }
    case 4:
    {
      cardano_pool_retirement_cert_t* old   = NULL;
      cardano_pool_retirement_cert_t* fresh = NULL;
      result                                = cardano_certificate_to_pool_retirement(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_pool_retirement(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_pool_retirement(fresh, output);
      }
      cardano_pool_retirement_cert_unref(&fresh);
      cardano_pool_retirement_cert_unref(&old);
      break;
    }
    case 5:
    {
      cardano_genesis_key_delegation_cert_t* old   = NULL;
      cardano_genesis_key_delegation_cert_t* fresh = NULL;
      result                                       = cardano_certificate_to_genesis_key_delegation(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_genesis_key_delegation(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_genesis_key_delegation(fresh, output);
      }
      cardano_genesis_key_delegation_cert_unref(&fresh);
      cardano_genesis_key_delegation_cert_unref(&old);
      break;
    }
    case 6:
    {
      cardano_mir_cert_t* old   = NULL;
      cardano_mir_cert_t* fresh = NULL;
      result                    = cardano_certificate_to_mir(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_mir(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_mir(fresh, output);
      }
      cardano_mir_cert_unref(&fresh);
      cardano_mir_cert_unref(&old);
      break;
    }
    case 7:
    {
      cardano_registration_cert_t* old   = NULL;
      cardano_registration_cert_t* fresh = NULL;
      result                             = cardano_certificate_to_registration(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_registration(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_registration(fresh, output);
      }
      cardano_registration_cert_unref(&fresh);
      cardano_registration_cert_unref(&old);
      break;
    }
    case 8:
    {
      cardano_unregistration_cert_t* old   = NULL;
      cardano_unregistration_cert_t* fresh = NULL;
      result                               = cardano_certificate_to_unregistration(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_unregistration(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_unregistration(fresh, output);
      }
      cardano_unregistration_cert_unref(&fresh);
      cardano_unregistration_cert_unref(&old);
      break;
    }
    case 9:
    {
      cardano_vote_delegation_cert_t* old   = NULL;
      cardano_vote_delegation_cert_t* fresh = NULL;
      result                                = cardano_certificate_to_vote_delegation(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_vote_delegation(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_vote_delegation(fresh, output);
      }
      cardano_vote_delegation_cert_unref(&fresh);
      cardano_vote_delegation_cert_unref(&old);
      break;
    }
    case 10:
    {
      cardano_stake_vote_delegation_cert_t* old   = NULL;
      cardano_stake_vote_delegation_cert_t* fresh = NULL;
      result                                      = cardano_certificate_to_stake_vote_delegation(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_stake_vote_delegation(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_stake_vote_delegation(fresh, output);
      }
      cardano_stake_vote_delegation_cert_unref(&fresh);
      cardano_stake_vote_delegation_cert_unref(&old);
      break;
    }
    case 11:
    {
      cardano_stake_registration_delegation_cert_t* old   = NULL;
      cardano_stake_registration_delegation_cert_t* fresh = NULL;
      result                                              = cardano_certificate_to_stake_registration_delegation(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_stake_registration_delegation(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_stake_registration_delegation(fresh, output);
      }
      cardano_stake_registration_delegation_cert_unref(&fresh);
      cardano_stake_registration_delegation_cert_unref(&old);
      break;
    }
    case 12:
    {
      cardano_vote_registration_delegation_cert_t* old   = NULL;
      cardano_vote_registration_delegation_cert_t* fresh = NULL;
      result                                             = cardano_certificate_to_vote_registration_delegation(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_vote_registration_delegation(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_vote_registration_delegation(fresh, output);
      }
      cardano_vote_registration_delegation_cert_unref(&fresh);
      cardano_vote_registration_delegation_cert_unref(&old);
      break;
    }
    case 13:
    {
      cardano_stake_vote_registration_delegation_cert_t* old   = NULL;
      cardano_stake_vote_registration_delegation_cert_t* fresh = NULL;
      result                                                   = cardano_certificate_to_stake_vote_registration_delegation(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_stake_vote_registration_delegation(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_stake_vote_registration_delegation(fresh, output);
      }
      cardano_stake_vote_registration_delegation_cert_unref(&fresh);
      cardano_stake_vote_registration_delegation_cert_unref(&old);
      break;
    }
    case 14:
    {
      cardano_auth_committee_hot_cert_t* old   = NULL;
      cardano_auth_committee_hot_cert_t* fresh = NULL;
      result                                   = cardano_certificate_to_auth_committee_hot(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_auth_committee_hot(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_auth_committee_hot(fresh, output);
      }
      cardano_auth_committee_hot_cert_unref(&fresh);
      cardano_auth_committee_hot_cert_unref(&old);
      break;
    }
    case 15:
    {
      cardano_resign_committee_cold_cert_t* old   = NULL;
      cardano_resign_committee_cold_cert_t* fresh = NULL;
      result                                      = cardano_certificate_to_resign_committee_cold(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_resign_committee_cold(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_resign_committee_cold(fresh, output);
      }
      cardano_resign_committee_cold_cert_unref(&fresh);
      cardano_resign_committee_cold_cert_unref(&old);
      break;
    }
    case 16:
    {
      cardano_register_drep_cert_t* old   = NULL;
      cardano_register_drep_cert_t* fresh = NULL;
      result                              = cardano_certificate_to_register_drep(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_register_drep(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_register_drep(fresh, output);
      }
      cardano_register_drep_cert_unref(&fresh);
      cardano_register_drep_cert_unref(&old);
      break;
    }
    case 17:
    {
      cardano_unregister_drep_cert_t* old   = NULL;
      cardano_unregister_drep_cert_t* fresh = NULL;
      result                                = cardano_certificate_to_unregister_drep(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_unregister_drep(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_unregister_drep(fresh, output);
      }
      cardano_unregister_drep_cert_unref(&fresh);
      cardano_unregister_drep_cert_unref(&old);
      break;
    }
    case 18:
    {
      cardano_update_drep_cert_t* old   = NULL;
      cardano_update_drep_cert_t* fresh = NULL;
      result                            = cardano_certificate_to_update_drep(source, &old);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_update_drep(old, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_certificate_new_update_drep(fresh, output);
      }
      cardano_update_drep_cert_unref(&fresh);
      cardano_update_drep_cert_unref(&old);
      break;
    }
    default:
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      break;
  }
  return result;
}

/** \brief Reconstructs collection entries in order, retaining duplicates. */
static cardano_error_t
rebuild_collection(cardano_certificate_set_t* source, cardano_certificate_set_t** output)
{
  cardano_error_t result = cardano_certificate_set_new(output);
  for (size_t index = 0; result == CARDANO_SUCCESS && index < cardano_certificate_set_get_length(source); ++index)
  {
    cardano_certificate_t* old   = NULL;
    cardano_certificate_t* fresh = NULL;
    result                       = cardano_certificate_set_get(source, index, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_certificate(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_certificate_set_add(*output, fresh);
    }
    cardano_certificate_unref(&fresh);
    cardano_certificate_unref(&old);
  }
  return result;
}

/* DEFINITIONS ****************************************************************/

/** \brief Compares fresh native reconstruction against fresh public Haskell CBOR.
 * Input bytes remain borrowed throughout this synchronous call. Every parser,
 * writer, buffer and certificate reference is released before return.
 * kind 0 selects a certificate; kind 1 selects an ordered certificate collection.
 */
int
cometa_test_certificates_agree(unsigned int kind, const unsigned char* input, size_t size)
{
  cardano_cbor_reader_t* reader = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  cardano_buffer_t*      buffer = NULL;
  cardano_error_t        result = CARDANO_SUCCESS;
  int                    agrees = 0;
  if (reader == NULL || writer == NULL)
  {
    goto cleanup;
  }
  if (kind == 0)
  {
    cardano_certificate_t* old   = NULL;
    cardano_certificate_t* fresh = NULL;
    result                       = cardano_certificate_from_cbor(reader, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_certificate(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_certificate_to_cbor(fresh, writer);
    }
    cardano_certificate_unref(&fresh);
    cardano_certificate_unref(&old);
  }
  else
  {
    cardano_certificate_set_t* old   = NULL;
    cardano_certificate_set_t* fresh = NULL;
    result                           = cardano_certificate_set_from_cbor(reader, &old);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_collection(old, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_certificate_set_to_cbor(fresh, writer);
    }
    cardano_certificate_set_unref(&fresh);
    cardano_certificate_set_unref(&old);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &buffer);
  }
  if (result == CARDANO_SUCCESS)
  {
    agrees = cardano_buffer_get_size(buffer) == size && memcmp(cardano_buffer_get_data(buffer), input, size) == 0;
  }
cleanup:
  cardano_buffer_unref(&buffer);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return agrees;
}
