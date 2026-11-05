/**
 * \file proposals_oracle.c
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

/**
 * \brief Reconstructs parameter change action using getter snapshots and a fresh constructor.
 * Getters return retained references; the constructor retains its inputs. Every
 * local getter reference is released once, including optional null references.
 * Nested components are validated by their dedicated domain differential tests.
 */
static cardano_error_t
rebuild_parameter_change_action(cardano_parameter_change_action_t* source, cardano_parameter_change_action_t** output)
{
  cardano_protocol_param_update_t* protocol_param_update = cardano_parameter_change_action_get_protocol_param_update(source);
  cardano_governance_action_id_t*  governance_action_id  = cardano_parameter_change_action_get_governance_action_id(source);
  cardano_blake2b_hash_t*          policy_hash           = cardano_parameter_change_action_get_policy_hash(source);
  cardano_error_t                  result                = cardano_parameter_change_action_new(protocol_param_update, governance_action_id, policy_hash, output);
  cardano_protocol_param_update_unref(&protocol_param_update);
  cardano_governance_action_id_unref(&governance_action_id);
  cardano_blake2b_hash_unref(&policy_hash);
  return result;
}

/**
 * \brief Reconstructs hard fork initiation action using getter snapshots and a fresh constructor.
 * Getters return retained references; the constructor retains its inputs. Every
 * local getter reference is released once, including optional null references.
 * Nested components are validated by their dedicated domain differential tests.
 */
static cardano_error_t
rebuild_hard_fork_initiation_action(cardano_hard_fork_initiation_action_t* source, cardano_hard_fork_initiation_action_t** output)
{
  cardano_protocol_version_t*     protocol_version     = cardano_hard_fork_initiation_action_get_protocol_version(source);
  cardano_governance_action_id_t* governance_action_id = cardano_hard_fork_initiation_action_get_governance_action_id(source);
  cardano_error_t                 result               = cardano_hard_fork_initiation_action_new(protocol_version, governance_action_id, output);
  cardano_protocol_version_unref(&protocol_version);
  cardano_governance_action_id_unref(&governance_action_id);
  return result;
}

/**
 * \brief Rebuilds withdrawals from retained indexed accounts and scalar lovelace.
 * Fresh insertion exercises native byte ordering independently of cached source
 * map CBOR. Each account is retained by the getter and released after insertion.
 */
static cardano_error_t
rebuild_withdrawal_map(cardano_withdrawal_map_t* source, cardano_withdrawal_map_t** output)
{
  cardano_error_t result = cardano_withdrawal_map_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_withdrawal_map_get_length(source); ++i)
  {
    cardano_reward_address_t* account = NULL;
    uint64_t                  amount  = 0;
    result                            = cardano_withdrawal_map_get_key_value_at(source, i, &account, &amount);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_withdrawal_map_insert(*output, account, amount);
    }
    cardano_reward_address_unref(&account);
  }
  return result;
}

/**
 * \brief Reconstructs treasury withdrawals action using getter snapshots and a fresh constructor.
 * Getters return retained references; the constructor retains its inputs. Every
 * local getter reference is released once, including optional null references.
 * Nested components are validated by their dedicated domain differential tests.
 */
static cardano_error_t
rebuild_treasury_withdrawals_action(cardano_treasury_withdrawals_action_t* source, cardano_treasury_withdrawals_action_t** output)
{
  cardano_withdrawal_map_t* withdrawals = cardano_treasury_withdrawals_action_get_withdrawals(source);
  cardano_blake2b_hash_t*   policy_hash = cardano_treasury_withdrawals_action_get_policy_hash(source);
  cardano_withdrawal_map_t* fresh       = NULL;
  cardano_error_t           result      = rebuild_withdrawal_map(withdrawals, &fresh);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_treasury_withdrawals_action_new(fresh, policy_hash, output);
  }
  cardano_withdrawal_map_unref(&fresh);
  cardano_withdrawal_map_unref(&withdrawals);
  cardano_blake2b_hash_unref(&policy_hash);
  return result;
}

/**
 * \brief Reconstructs no confidence action using getter snapshots and a fresh constructor.
 * Getters return retained references; the constructor retains its inputs. Every
 * local getter reference is released once, including optional null references.
 * Nested components are validated by their dedicated domain differential tests.
 */
static cardano_error_t
rebuild_no_confidence_action(cardano_no_confidence_action_t* source, cardano_no_confidence_action_t** output)
{
  cardano_governance_action_id_t* governance_action_id = cardano_no_confidence_action_get_governance_action_id(source);
  cardano_error_t                 result               = cardano_no_confidence_action_new(governance_action_id, output);
  cardano_governance_action_id_unref(&governance_action_id);
  return result;
}

/**
 * \brief Reconstructs update committee action using getter snapshots and a fresh constructor.
 * Getters return retained references; the constructor retains its inputs. Every
 * local getter reference is released once, including optional null references.
 * Nested components are validated by their dedicated domain differential tests.
 */
static cardano_error_t
rebuild_update_committee_action(cardano_update_committee_action_t* source, cardano_update_committee_action_t** output)
{
  cardano_credential_set_t*        members_to_be_removed = cardano_update_committee_action_get_members_to_be_removed(source);
  cardano_committee_members_map_t* members_to_be_added   = cardano_update_committee_action_get_members_to_be_added(source);
  cardano_unit_interval_t*         quorum                = cardano_update_committee_action_get_quorum(source);
  cardano_governance_action_id_t*  governance_action_id  = cardano_update_committee_action_get_governance_action_id(source);
  cardano_error_t                  result                = cardano_update_committee_action_new(members_to_be_removed, members_to_be_added, quorum, governance_action_id, output);
  cardano_credential_set_unref(&members_to_be_removed);
  cardano_committee_members_map_unref(&members_to_be_added);
  cardano_unit_interval_unref(&quorum);
  cardano_governance_action_id_unref(&governance_action_id);
  return result;
}

/**
 * \brief Reconstructs new constitution action using getter snapshots and a fresh constructor.
 * Getters return retained references; the constructor retains its inputs. Every
 * local getter reference is released once, including optional null references.
 * Nested components are validated by their dedicated domain differential tests.
 */
static cardano_error_t
rebuild_new_constitution_action(cardano_new_constitution_action_t* source, cardano_new_constitution_action_t** output)
{
  cardano_constitution_t*         constitution         = cardano_new_constitution_action_get_constitution(source);
  cardano_governance_action_id_t* governance_action_id = cardano_new_constitution_action_get_governance_action_id(source);
  cardano_error_t                 result               = cardano_new_constitution_action_new(constitution, governance_action_id, output);
  cardano_constitution_unref(&constitution);
  cardano_governance_action_id_unref(&governance_action_id);
  return result;
}

/**
 * \brief Reconstructs constitution using getter snapshots and a fresh constructor.
 * Getters return retained references; the constructor retains its inputs. Every
 * local getter reference is released once, including optional null references.
 * Nested components are validated by their dedicated domain differential tests.
 */
static cardano_error_t
rebuild_constitution(cardano_constitution_t* source, cardano_constitution_t** output)
{
  cardano_anchor_t*       anchor      = cardano_constitution_get_anchor(source);
  cardano_blake2b_hash_t* script_hash = cardano_constitution_get_script_hash(source);
  cardano_error_t         result      = cardano_constitution_new(anchor, script_hash, output);
  cardano_anchor_unref(&anchor);
  cardano_blake2b_hash_unref(&script_hash);
  return result;
}

/** \brief Creates a fresh zero-field informational action. */
static cardano_error_t
rebuild_info_action(cardano_info_action_t* source, cardano_info_action_t** output)
{
  (void)source;
  return cardano_info_action_new(output);
}

/**
 * \brief Rebuilds a committee map through retained indexed keys and scalar epochs.
 * Loop keys are nulled after unref because the source map keeps them alive.
 */
static cardano_error_t
rebuild_committee_members_map(cardano_committee_members_map_t* source, cardano_committee_members_map_t** output)
{
  cardano_error_t result = cardano_committee_members_map_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_committee_members_map_get_length(source); ++i)
  {
    cardano_credential_t* key   = NULL;
    uint64_t              epoch = 0;
    result                      = cardano_committee_members_map_get_key_value_at(source, i, &key, &epoch);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_committee_members_map_insert(*output, key, epoch);
    }
    cardano_credential_unref(&key);
  }
  return result;
}

/** \brief Rebuilds the quorum and every member of a committee using indexed snapshots. */
static cardano_error_t
rebuild_committee(cardano_committee_t* source, cardano_committee_t** output)
{
  cardano_unit_interval_t*  quorum = cardano_committee_get_quorum_threshold(source);
  cardano_credential_set_t* keys   = NULL;
  cardano_error_t           result = cardano_committee_new(quorum, output);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_committee_members_keys(source, &keys);
  }
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_credential_set_get_length(keys); ++i)
  {
    cardano_credential_t* key   = NULL;
    uint64_t              epoch = 0;
    result                      = cardano_committee_get_key_value_at(source, i, &key, &epoch);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_committee_add_member(*output, key, epoch);
    }
    cardano_credential_unref(&key);
  }
  cardano_credential_set_unref(&keys);
  cardano_unit_interval_unref(&quorum);
  return result;
}

/** \brief Rebuilds sorted genesis update entries; getter outputs are retained owners. */
static cardano_error_t
rebuild_proposed_param_updates(cardano_proposed_param_updates_t* source, cardano_proposed_param_updates_t** output)
{
  cardano_error_t result = cardano_proposed_param_updates_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_proposed_param_updates_get_size(source); ++i)
  {
    cardano_blake2b_hash_t*          key   = NULL;
    cardano_protocol_param_update_t* value = NULL;
    result                                 = cardano_proposed_param_updates_get_key_value_at(source, i, &key, &value);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_proposed_param_updates_insert(*output, key, value);
    }
    cardano_blake2b_hash_unref(&key);
    cardano_protocol_param_update_unref(&value);
  }
  return result;
}

/**
 * \brief Rebuilds the legacy envelope and its map rather than forwarding source CBOR.
 * The proposed-parameters getter borrows its output from source; only fresh is
 * owned locally. Source remains alive through the reconstruction.
 */
static cardano_error_t
rebuild_update(cardano_update_t* source, cardano_update_t** output)
{
  uint64_t                          epoch   = 0;
  cardano_proposed_param_updates_t* changes = NULL;
  cardano_proposed_param_updates_t* fresh   = NULL;
  cardano_error_t                   result  = cardano_update_get_epoch(source, &epoch);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_update_get_proposed_parameters(source, &changes);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = rebuild_proposed_param_updates(changes, &fresh);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_update_new(epoch, fresh, output);
  }
  cardano_proposed_param_updates_unref(&fresh);
  return result;
}

/**
 * \brief Rebuilds a complete proposal using retained common fields and a fresh action.
 * All references returned by getters and to-action operations are released once.
 */
static cardano_error_t
rebuild_proposal_procedure(cardano_proposal_procedure_t* source, cardano_proposal_procedure_t** output)
{
  cardano_governance_action_type_t type;
  cardano_reward_address_t*        account = cardano_proposal_procedure_get_reward_address(source);
  cardano_anchor_t*                anchor  = cardano_proposal_procedure_get_anchor(source);
  uint64_t                         deposit = cardano_proposal_procedure_get_deposit(source);
  cardano_error_t                  result  = cardano_proposal_procedure_get_action_type(source, &type);
  if (result == CARDANO_SUCCESS)
  {
    switch (type)
    {
      case 0:
      {
        cardano_parameter_change_action_t* action = NULL;
        cardano_parameter_change_action_t* fresh  = NULL;
        result                                    = cardano_proposal_procedure_to_parameter_change_action(source, &action);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild_parameter_change_action(action, &fresh);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_proposal_procedure_new_parameter_change_action(deposit, account, anchor, fresh, output);
        }
        cardano_parameter_change_action_unref(&fresh);
        cardano_parameter_change_action_unref(&action);
        break;
      }
      case 1:
      {
        cardano_hard_fork_initiation_action_t* action = NULL;
        cardano_hard_fork_initiation_action_t* fresh  = NULL;
        result                                        = cardano_proposal_procedure_to_hard_fork_initiation_action(source, &action);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild_hard_fork_initiation_action(action, &fresh);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_proposal_procedure_new_hard_fork_initiation_action(deposit, account, anchor, fresh, output);
        }
        cardano_hard_fork_initiation_action_unref(&fresh);
        cardano_hard_fork_initiation_action_unref(&action);
        break;
      }
      case 2:
      {
        cardano_treasury_withdrawals_action_t* action = NULL;
        cardano_treasury_withdrawals_action_t* fresh  = NULL;
        result                                        = cardano_proposal_procedure_to_treasury_withdrawals_action(source, &action);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild_treasury_withdrawals_action(action, &fresh);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_proposal_procedure_new_treasury_withdrawals_action(deposit, account, anchor, fresh, output);
        }
        cardano_treasury_withdrawals_action_unref(&fresh);
        cardano_treasury_withdrawals_action_unref(&action);
        break;
      }
      case 3:
      {
        cardano_no_confidence_action_t* action = NULL;
        cardano_no_confidence_action_t* fresh  = NULL;
        result                                 = cardano_proposal_procedure_to_no_confidence_action(source, &action);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild_no_confidence_action(action, &fresh);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_proposal_procedure_new_no_confidence_action(deposit, account, anchor, fresh, output);
        }
        cardano_no_confidence_action_unref(&fresh);
        cardano_no_confidence_action_unref(&action);
        break;
      }
      case 4:
      {
        cardano_update_committee_action_t* action = NULL;
        cardano_update_committee_action_t* fresh  = NULL;
        result                                    = cardano_proposal_procedure_to_update_committee_action(source, &action);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild_update_committee_action(action, &fresh);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_proposal_procedure_new_update_committee_action(deposit, account, anchor, fresh, output);
        }
        cardano_update_committee_action_unref(&fresh);
        cardano_update_committee_action_unref(&action);
        break;
      }
      case 5:
      {
        cardano_new_constitution_action_t* action = NULL;
        cardano_new_constitution_action_t* fresh  = NULL;
        result                                    = cardano_proposal_procedure_to_constitution_action(source, &action);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild_new_constitution_action(action, &fresh);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_proposal_procedure_new_constitution_action(deposit, account, anchor, fresh, output);
        }
        cardano_new_constitution_action_unref(&fresh);
        cardano_new_constitution_action_unref(&action);
        break;
      }
      case 6:
      {
        cardano_info_action_t* action = NULL;
        cardano_info_action_t* fresh  = NULL;
        result                        = cardano_proposal_procedure_to_info_action(source, &action);
        if (result == CARDANO_SUCCESS)
        {
          result = rebuild_info_action(action, &fresh);
        }
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_proposal_procedure_new_info_action(deposit, account, anchor, fresh, output);
        }
        cardano_info_action_unref(&fresh);
        cardano_info_action_unref(&action);
        break;
      }
      default:
        result = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
    }
  }
  cardano_anchor_unref(&anchor);
  cardano_reward_address_unref(&account);
  return result;
}

/** \brief Rebuilds an ordered proposal collection, preserving duplicates and indices. */
static cardano_error_t
rebuild_proposal_procedure_set(cardano_proposal_procedure_set_t* source, cardano_proposal_procedure_set_t** output)
{
  cardano_error_t result = cardano_proposal_procedure_set_new(output);
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_proposal_procedure_set_get_length(source); ++i)
  {
    cardano_proposal_procedure_t* value = NULL;
    cardano_proposal_procedure_t* fresh = NULL;
    result                              = cardano_proposal_procedure_set_get(source, i, &value);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_proposal_procedure(value, &fresh);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_proposal_procedure_set_add(*output, fresh);
    }
    cardano_proposal_procedure_unref(&fresh);
    cardano_proposal_procedure_unref(&value);
  }
  return result;
}

/* DEFINITIONS ***************************************************************/

/**
 * \brief Checks fresh native construction against Haskell-owned semantic CBOR.
 * Modes 0..6 are action variants, 7 constitution, 8 committee, 9 members,
 * 10 proposal, 11 proposals, 12 legacy update map, 13 legacy envelope.
 * Input bytes are borrowed through return. All readers, writers, source and
 * reconstructed owners are deterministically released, including error paths.
 */
int
cometa_test_proposals_agreement(unsigned int mode, const unsigned char* input, size_t size)
{
  cardano_cbor_reader_t* reader  = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_buffer_t*      encoded = NULL;
  cardano_error_t        result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  int                    agrees  = 0;
  if (reader == NULL || writer == NULL)
  {
    goto cleanup;
  }
  switch (mode)
  {
    case 0:
    {
      cardano_parameter_change_action_t* source = NULL;
      cardano_parameter_change_action_t* fresh  = NULL;
      result                                    = cardano_parameter_change_action_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_parameter_change_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_parameter_change_action_to_cbor(fresh, writer);
      }
      cardano_parameter_change_action_unref(&fresh);
      cardano_parameter_change_action_unref(&source);
      break;
    }
    case 1:
    {
      cardano_hard_fork_initiation_action_t* source = NULL;
      cardano_hard_fork_initiation_action_t* fresh  = NULL;
      result                                        = cardano_hard_fork_initiation_action_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_hard_fork_initiation_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_hard_fork_initiation_action_to_cbor(fresh, writer);
      }
      cardano_hard_fork_initiation_action_unref(&fresh);
      cardano_hard_fork_initiation_action_unref(&source);
      break;
    }
    case 2:
    {
      cardano_treasury_withdrawals_action_t* source = NULL;
      cardano_treasury_withdrawals_action_t* fresh  = NULL;
      result                                        = cardano_treasury_withdrawals_action_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_treasury_withdrawals_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_treasury_withdrawals_action_to_cbor(fresh, writer);
      }
      cardano_treasury_withdrawals_action_unref(&fresh);
      cardano_treasury_withdrawals_action_unref(&source);
      break;
    }
    case 3:
    {
      cardano_no_confidence_action_t* source = NULL;
      cardano_no_confidence_action_t* fresh  = NULL;
      result                                 = cardano_no_confidence_action_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_no_confidence_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_no_confidence_action_to_cbor(fresh, writer);
      }
      cardano_no_confidence_action_unref(&fresh);
      cardano_no_confidence_action_unref(&source);
      break;
    }
    case 4:
    {
      cardano_update_committee_action_t* source = NULL;
      cardano_update_committee_action_t* fresh  = NULL;
      result                                    = cardano_update_committee_action_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_update_committee_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_update_committee_action_to_cbor(fresh, writer);
      }
      cardano_update_committee_action_unref(&fresh);
      cardano_update_committee_action_unref(&source);
      break;
    }
    case 5:
    {
      cardano_new_constitution_action_t* source = NULL;
      cardano_new_constitution_action_t* fresh  = NULL;
      result                                    = cardano_new_constitution_action_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_new_constitution_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_new_constitution_action_to_cbor(fresh, writer);
      }
      cardano_new_constitution_action_unref(&fresh);
      cardano_new_constitution_action_unref(&source);
      break;
    }
    case 6:
    {
      cardano_info_action_t* source = NULL;
      cardano_info_action_t* fresh  = NULL;
      result                        = cardano_info_action_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_info_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_info_action_to_cbor(fresh, writer);
      }
      cardano_info_action_unref(&fresh);
      cardano_info_action_unref(&source);
      break;
    }
    case 7:
    {
      cardano_constitution_t* source = NULL;
      cardano_constitution_t* fresh  = NULL;
      result                         = cardano_constitution_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_constitution(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_constitution_to_cbor(fresh, writer);
      }
      cardano_constitution_unref(&fresh);
      cardano_constitution_unref(&source);
      break;
    }
    case 8:
    {
      cardano_committee_t* source = NULL;
      cardano_committee_t* fresh  = NULL;
      result                      = cardano_committee_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_committee(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_committee_to_cbor(fresh, writer);
      }
      cardano_committee_unref(&fresh);
      cardano_committee_unref(&source);
      break;
    }
    case 9:
    {
      cardano_committee_members_map_t* source = NULL;
      cardano_committee_members_map_t* fresh  = NULL;
      result                                  = cardano_committee_members_map_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_committee_members_map(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_committee_members_map_to_cbor(fresh, writer);
      }
      cardano_committee_members_map_unref(&fresh);
      cardano_committee_members_map_unref(&source);
      break;
    }
    case 10:
    {
      cardano_proposal_procedure_t* source = NULL;
      cardano_proposal_procedure_t* fresh  = NULL;
      result                               = cardano_proposal_procedure_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_proposal_procedure(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_proposal_procedure_to_cbor(fresh, writer);
      }
      cardano_proposal_procedure_unref(&fresh);
      cardano_proposal_procedure_unref(&source);
      break;
    }
    case 11:
    {
      cardano_proposal_procedure_set_t* source = NULL;
      cardano_proposal_procedure_set_t* fresh  = NULL;
      result                                   = cardano_proposal_procedure_set_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_proposal_procedure_set(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_proposal_procedure_set_to_cbor(fresh, writer);
      }
      cardano_proposal_procedure_set_unref(&fresh);
      cardano_proposal_procedure_set_unref(&source);
      break;
    }
    case 12:
    {
      cardano_proposed_param_updates_t* source = NULL;
      cardano_proposed_param_updates_t* fresh  = NULL;
      result                                   = cardano_proposed_param_updates_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_proposed_param_updates(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_proposed_param_updates_to_cbor(fresh, writer);
      }
      cardano_proposed_param_updates_unref(&fresh);
      cardano_proposed_param_updates_unref(&source);
      break;
    }
    case 13:
    {
      cardano_update_t* source = NULL;
      cardano_update_t* fresh  = NULL;
      result                   = cardano_update_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_update(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_update_to_cbor(fresh, writer);
      }
      cardano_update_unref(&fresh);
      cardano_update_unref(&source);
      break;
    }
    default:
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      break;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  }
  if (result == CARDANO_SUCCESS)
  {
    agrees = cardano_buffer_get_size(encoded) == size && memcmp(cardano_buffer_get_data(encoded), input, size) == 0;
  }
cleanup:
  cardano_buffer_unref(&encoded);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return agrees;
}
