/**
 * \file cometa_transaction_builder.c
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

#include "cometa_transaction_builder.h"
#include "cometa_coin_selection.h"
#include "cometa_evaluation.h"
#include "cometa_parameters.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* TYPES *********************************************************************/

/* Deferred contexts borrow the grouped runtime. Storage is allocated before
 * registration and freed only after builder destruction; native lists neither
 * retain nor release user_context. Each reply transfers a fresh payload. */
typedef struct
{
    cometa_runtime_t* runtime;
    uint64_t          index;
    bool              deferred_mint;
    bool              deferred_vote;
} deferred_context_t;

/* STATIC FUNCTIONS **********************************************************/

/** \brief Reject trailing bytes in every embedded native object. */
static cardano_error_t
complete(cardano_cbor_reader_t* reader)
{
  size_t          remaining = 0U;
  cardano_error_t result    = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
  return result == CARDANO_SUCCESS && remaining != 0U ? CARDANO_ERROR_DECODING : result;
}

/** \brief Read one complete definite array with the expected arity. */
static cardano_error_t
array(cardano_cbor_reader_t* reader, int64_t expected)
{
  int64_t         count  = 0;
  cardano_error_t result = cardano_cbor_reader_read_start_array(reader, &count);
  return result == CARDANO_SUCCESS && count != expected ? CARDANO_ERROR_DECODING : result;
}

/** \brief Decode a byte-string-wrapped native object; empty data means absence
 * only for explicitly optional datum arguments. Each returned object is owned. */
#define READ_OBJECT(NAME, TYPE, FROM)                                                                   \
  static cardano_error_t NAME(cardano_cbor_reader_t* reader, TYPE** output)                             \
  {                                                                                                     \
    cardano_buffer_t*      bytes  = NULL;                                                               \
    cardano_cbor_reader_t* nested = NULL;                                                               \
    cardano_error_t        result = cardano_cbor_reader_read_bytestring(reader, &bytes);                \
    *output                       = NULL;                                                               \
    if (result == CARDANO_SUCCESS && cardano_buffer_get_size(bytes) != 0U)                              \
    {                                                                                                   \
      nested = cardano_cbor_reader_new(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes)); \
      result = nested == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : FROM(nested, output);          \
      if (result == CARDANO_SUCCESS)                                                                    \
        result = complete(nested);                                                                      \
    }                                                                                                   \
    cardano_cbor_reader_unref(&nested);                                                                 \
    cardano_buffer_unref(&bytes);                                                                       \
    return result;                                                                                      \
  }

READ_OBJECT(read_output, cardano_transaction_output_t, cardano_transaction_output_from_cbor)
READ_OBJECT(read_utxo, cardano_utxo_t, cardano_utxo_from_cbor)
READ_OBJECT(read_script, cardano_script_t, cardano_script_from_cbor)
READ_OBJECT(read_data, cardano_plutus_data_t, cardano_plutus_data_from_cbor)
READ_OBJECT(read_certificate, cardano_certificate_t, cardano_certificate_from_cbor)
READ_OBJECT(read_metadata, cardano_metadatum_t, cardano_metadatum_from_cbor)
READ_OBJECT(read_credential, cardano_credential_t, cardano_credential_from_cbor)
READ_OBJECT(read_interval, cardano_account_balance_interval_t, cardano_account_balance_interval_from_cbor)
READ_OBJECT(read_proposal, cardano_proposal_procedure_t, cardano_proposal_procedure_from_cbor)
READ_OBJECT(read_voter, cardano_voter_t, cardano_voter_from_cbor)
READ_OBJECT(read_action_id, cardano_governance_action_id_t, cardano_governance_action_id_from_cbor)
READ_OBJECT(read_procedure, cardano_voting_procedure_t, cardano_voting_procedure_from_cbor)
READ_OBJECT(read_sub, cardano_sub_transaction_t, cardano_sub_transaction_from_cbor)
#undef READ_OBJECT

/** \brief Address factories copy their byte-string input before buffer release. */
static cardano_error_t
read_address(cardano_cbor_reader_t* reader, cardano_address_t** output)
{
  cardano_buffer_t* bytes  = NULL;
  cardano_error_t   result = cardano_cbor_reader_read_bytestring(reader, &bytes);
  if (result == CARDANO_SUCCESS && cardano_buffer_get_size(bytes) != 0U)
  {
    result = cardano_address_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), output);
  }
  cardano_buffer_unref(&bytes);
  return result;
}

/** \brief Materialize a list; list insertion retains each locally released item. */
static cardano_error_t
read_utxos(cardano_cbor_reader_t* reader, cardano_utxo_list_t** output)
{
  int64_t         count  = 0;
  cardano_error_t result = cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS && count < 0)
  {
    result = CARDANO_ERROR_DECODING;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_utxo_list_new(output);
  }
  for (int64_t i = 0; result == CARDANO_SUCCESS && i < count; ++i)
  {
    cardano_utxo_t* item = NULL;
    result               = cardano_utxo_from_cbor(reader, &item);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_list_add(*output, item);
    }
    cardano_utxo_unref(&item);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
  return result;
}

/** \brief Copy a balanced draft into the protected callback and transfer its argument. */
static cardano_error_t
deferred_callback(void* opaque, cardano_transaction_t* transaction, cardano_utxo_list_t* inputs, cardano_plutus_data_t** output)
{
  deferred_context_t*    context = (deferred_context_t*)opaque;
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_cbor_reader_t* reader  = NULL;
  cardano_buffer_t*      request = NULL;
  cardano_buffer_t*      reply   = NULL;
  cardano_error_t        result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  *output                        = NULL;
  if (writer == NULL)
  {
    goto cleanup;
  }
  result = cardano_cbor_writer_write_start_array(writer, 3);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_uint(writer, context->index);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_transaction_to_cbor(transaction, writer);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_write_start_array(writer, (int64_t)cardano_utxo_list_get_length(inputs));
  }
  for (size_t i = 0; result == CARDANO_SUCCESS && i < cardano_utxo_list_get_length(inputs); ++i)
  {
    cardano_utxo_t* input = NULL;
    result                = cardano_utxo_list_get(inputs, i, &input);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_to_cbor(input, writer);
    }
    cardano_utxo_unref(&input);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &request);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = (cardano_error_t)cometa_runtime_dispatch(context->runtime, 110, cardano_buffer_get_data(request), cardano_buffer_get_size(request), &reply, NULL, 0);
  }
  if (result == CARDANO_SUCCESS && reply == NULL)
  {
    result = CARDANO_ERROR_POINTER_IS_NULL;
  }
  if (result == CARDANO_SUCCESS)
  {
    reader = cardano_cbor_reader_new(cardano_buffer_get_data(reply), cardano_buffer_get_size(reply));
    result = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : cardano_plutus_data_from_cbor(reader, output);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = complete(reader);
  }
cleanup:
  if (result != CARDANO_SUCCESS)
  {
    cardano_plutus_data_unref(output);
  }
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_writer_unref(&writer);
  cardano_buffer_unref(&request);
  cardano_buffer_unref(&reply);
  return result;
}

/* Proposal conversion/getters return retained references; each helper releases
 * them after the native builder has retained its independently built proposal.
 * The placeholder serialized deposit is intentionally replaced by protocol state. */
static cardano_error_t
apply_proposal(cardano_tx_builder_t* builder, cardano_proposal_procedure_t* proposal)
{
  cardano_reward_address_t*        account = cardano_proposal_procedure_get_reward_address(proposal);
  cardano_anchor_t*                anchor  = cardano_proposal_procedure_get_anchor(proposal);
  cardano_governance_action_type_t kind;
  cardano_error_t                  result = cardano_proposal_procedure_get_action_type(proposal, &kind);
  if (result == CARDANO_SUCCESS)
  {
    switch (kind)
    {
      case 0:
      {
        cardano_parameter_change_action_t* action = NULL;
        result                                    = cardano_proposal_procedure_to_parameter_change_action(proposal, &action);
        if (result == CARDANO_SUCCESS)
        {
          cardano_protocol_param_update_t* protocol_param_update = cardano_parameter_change_action_get_protocol_param_update(action);
          cardano_governance_action_id_t*  governance_action_id  = cardano_parameter_change_action_get_governance_action_id(action);
          cardano_blake2b_hash_t*          policy_hash           = cardano_parameter_change_action_get_policy_hash(action);
          cardano_tx_builder_propose_parameter_change(builder, account, anchor, protocol_param_update, governance_action_id, policy_hash);
          cardano_protocol_param_update_unref(&protocol_param_update);
          cardano_governance_action_id_unref(&governance_action_id);
          cardano_blake2b_hash_unref(&policy_hash);
        }
        cardano_parameter_change_action_unref(&action);
        break;
      }
      case 1:
      {
        cardano_hard_fork_initiation_action_t* action = NULL;
        result                                        = cardano_proposal_procedure_to_hard_fork_initiation_action(proposal, &action);
        if (result == CARDANO_SUCCESS)
        {
          cardano_protocol_version_t*     protocol_version     = cardano_hard_fork_initiation_action_get_protocol_version(action);
          cardano_governance_action_id_t* governance_action_id = cardano_hard_fork_initiation_action_get_governance_action_id(action);
          cardano_tx_builder_propose_hardfork(builder, account, anchor, protocol_version, governance_action_id);
          cardano_protocol_version_unref(&protocol_version);
          cardano_governance_action_id_unref(&governance_action_id);
        }
        cardano_hard_fork_initiation_action_unref(&action);
        break;
      }
      case 2:
      {
        cardano_treasury_withdrawals_action_t* action = NULL;
        result                                        = cardano_proposal_procedure_to_treasury_withdrawals_action(proposal, &action);
        if (result == CARDANO_SUCCESS)
        {
          cardano_withdrawal_map_t* withdrawals = cardano_treasury_withdrawals_action_get_withdrawals(action);
          cardano_blake2b_hash_t*   policy_hash = cardano_treasury_withdrawals_action_get_policy_hash(action);
          cardano_tx_builder_propose_treasury_withdrawals(builder, account, anchor, withdrawals, policy_hash);
          cardano_withdrawal_map_unref(&withdrawals);
          cardano_blake2b_hash_unref(&policy_hash);
        }
        cardano_treasury_withdrawals_action_unref(&action);
        break;
      }
      case 3:
      {
        cardano_no_confidence_action_t* action = NULL;
        result                                 = cardano_proposal_procedure_to_no_confidence_action(proposal, &action);
        if (result == CARDANO_SUCCESS)
        {
          cardano_governance_action_id_t* governance_action_id = cardano_no_confidence_action_get_governance_action_id(action);
          cardano_tx_builder_propose_no_confidence(builder, account, anchor, governance_action_id);
          cardano_governance_action_id_unref(&governance_action_id);
        }
        cardano_no_confidence_action_unref(&action);
        break;
      }
      case 4:
      {
        cardano_update_committee_action_t* action = NULL;
        result                                    = cardano_proposal_procedure_to_update_committee_action(proposal, &action);
        if (result == CARDANO_SUCCESS)
        {
          cardano_governance_action_id_t*  governance_action_id  = cardano_update_committee_action_get_governance_action_id(action);
          cardano_credential_set_t*        members_to_be_removed = cardano_update_committee_action_get_members_to_be_removed(action);
          cardano_committee_members_map_t* members_to_be_added   = cardano_update_committee_action_get_members_to_be_added(action);
          cardano_unit_interval_t*         quorum                = cardano_update_committee_action_get_quorum(action);
          cardano_tx_builder_propose_update_committee(builder, account, anchor, governance_action_id, members_to_be_removed, members_to_be_added, quorum);
          cardano_governance_action_id_unref(&governance_action_id);
          cardano_credential_set_unref(&members_to_be_removed);
          cardano_committee_members_map_unref(&members_to_be_added);
          cardano_unit_interval_unref(&quorum);
        }
        cardano_update_committee_action_unref(&action);
        break;
      }
      case 5:
      {
        cardano_new_constitution_action_t* action = NULL;
        result                                    = cardano_proposal_procedure_to_constitution_action(proposal, &action);
        if (result == CARDANO_SUCCESS)
        {
          cardano_governance_action_id_t* governance_action_id = cardano_new_constitution_action_get_governance_action_id(action);
          cardano_constitution_t*         constitution         = cardano_new_constitution_action_get_constitution(action);
          cardano_tx_builder_propose_new_constitution(builder, account, anchor, governance_action_id, constitution);
          cardano_governance_action_id_unref(&governance_action_id);
          cardano_constitution_unref(&constitution);
        }
        cardano_new_constitution_action_unref(&action);
        break;
      }
      case 6:
        cardano_tx_builder_propose_info(builder, account, anchor);
        break;
      default:
        result = CARDANO_ERROR_DECODING;
        break;
    }
  }
  cardano_reward_address_unref(&account);
  cardano_anchor_unref(&anchor);
  return result;
}

/** \brief Apply one instruction, releasing local references after builder retention. */
static cardano_error_t
instruction(cardano_tx_builder_t* builder, cardano_cbor_reader_t* reader, cardano_utxo_list_t* resolved, deferred_context_t* contexts, size_t position)
{
  deferred_context_t*                 context   = &contexts[position];
  static const int64_t                arities[] = { 2, 4, 2, 2, 5, 3, 2, 3, 4, 2, 2, 2, 4, 5, 3, 4, 3, 0, 3, 3, 3, 2, 2, 5, 5, 3 };
  int64_t                             count     = 0;
  uint64_t                            tag = 0U, number = 0U;
  int64_t                             signed_number = 0;
  cardano_transaction_output_t*       output        = NULL;
  cardano_utxo_t*                     utxo          = NULL;
  cardano_script_t*                   script        = NULL;
  cardano_plutus_data_t*              redeemer      = NULL;
  cardano_plutus_data_t*              datum         = NULL;
  cardano_certificate_t*              certificate   = NULL;
  cardano_metadatum_t*                metadata      = NULL;
  cardano_blake2b_hash_t*             hash          = NULL;
  cardano_asset_name_t*               asset_name    = NULL;
  cardano_reward_address_t*           reward        = NULL;
  cardano_credential_t*               credential    = NULL;
  cardano_account_balance_interval_t* interval      = NULL;
  cardano_proposal_procedure_t*       proposal      = NULL;
  cardano_voter_t*                    voter         = NULL;
  cardano_governance_action_id_t*     action_id     = NULL;
  cardano_voting_procedure_t*         procedure     = NULL;
  cardano_sub_transaction_t*          sub           = NULL;
  cardano_utxo_list_t*                sub_resolved  = NULL;
  cardano_buffer_t*                   bytes         = NULL;
  cardano_error_t                     result        = cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_uint(reader, &tag);
  }
  if (result == CARDANO_SUCCESS && (tag >= sizeof(arities) / sizeof(arities[0]) || count != arities[tag]))
  {
    result = CARDANO_ERROR_DECODING;
  }
  if (result != CARDANO_SUCCESS)
  {
    return result;
  }
#define TRY(CALL)                  \
  do                               \
  {                                \
    result = (CALL);               \
    if (result != CARDANO_SUCCESS) \
    {                              \
      goto cleanup;                \
    }                              \
  }                                \
  while (0)
  switch (tag)
  {
    case 0:
      TRY(read_output(reader, &output));
      cardano_tx_builder_add_output(builder, output);
      break;
    case 12:
    case 1:
      TRY(read_utxo(reader, &utxo));
      if (tag == 12)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &context->index));
      }
      else
      {
        TRY(read_data(reader, &redeemer));
      }
      TRY(read_data(reader, &datum));
      TRY(cardano_utxo_list_add(resolved, utxo));
      if (tag == 12)
      {
        cardano_tx_builder_add_input_with_deferred_redeemer(builder, utxo, deferred_callback, context, datum);
      }
      else
      {
        cardano_tx_builder_add_input(builder, utxo, redeemer, datum);
      }
      break;
    case 2:
      TRY(read_utxo(reader, &utxo));
      TRY(cardano_utxo_list_add(resolved, utxo));
      cardano_tx_builder_add_reference_input(builder, utxo);
      break;
    case 3:
      TRY(read_script(reader, &script));
      cardano_tx_builder_add_script(builder, script);
      break;
    case 13:
    case 4:
      TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
      TRY(cardano_blake2b_hash_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &hash));
      cardano_buffer_unref(&bytes);
      TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
      TRY(cardano_asset_name_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &asset_name));
      TRY(cardano_cbor_reader_read_int(reader, &signed_number));
      if (tag == 13)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &context->index));
        bool registered = false;
        for (size_t i = 0; i < position; ++i)
        {
          if (contexts[i].deferred_mint && contexts[i].index == context->index)
          {
            registered = true;
          }
        }
        context->deferred_mint = true;
        if (registered)
        {
          cardano_tx_builder_mint_token(builder, hash, asset_name, signed_number, NULL);
        }
        else
        {
          cardano_tx_builder_mint_token_with_deferred_redeemer(builder, hash, asset_name, signed_number, deferred_callback, context);
        }
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_tx_builder_mint_token(builder, hash, asset_name, signed_number, redeemer);
      }
      break;
    case 5:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      TRY(read_metadata(reader, &metadata));
      cardano_tx_builder_set_metadata(builder, number, metadata);
      break;
    case 6:
      TRY(read_data(reader, &datum));
      cardano_tx_builder_add_datum(builder, datum);
      break;
    case 14:
    case 7:
      TRY(read_certificate(reader, &certificate));
      if (tag == 14)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &context->index));
        cardano_tx_builder_add_certificate_with_deferred_redeemer(builder, certificate, deferred_callback, context);
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_tx_builder_add_certificate(builder, certificate, redeemer);
      }
      break;
    case 15:
    case 8:
      TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
      TRY(cardano_reward_address_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &reward));
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      if (number > INT64_MAX)
      {
        result = CARDANO_ERROR_INTEGER_OVERFLOW;
        goto cleanup;
      }
      if (tag == 15)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &context->index));
        cardano_tx_builder_withdraw_rewards_with_deferred_redeemer(builder, reward, (int64_t)number, deferred_callback, context);
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_tx_builder_withdraw_rewards(builder, reward, (int64_t)number, redeemer);
      }
      break;
    case 9:
      TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
      TRY(cardano_blake2b_hash_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &hash));
      cardano_tx_builder_add_signer(builder, hash);
      break;
    case 10:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      cardano_tx_builder_set_invalid_before(builder, number);
      break;
    case 11:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      cardano_tx_builder_set_invalid_after(builder, number);
      break;
    case 16:
      TRY(read_credential(reader, &credential));
      TRY(read_data(reader, &redeemer));
      if (redeemer == NULL)
      {
        cardano_tx_builder_add_guard(builder, credential);
      }
      else
      {
        cardano_tx_builder_add_guard_with_redeemer(builder, credential, redeemer);
      }
      break;
    case 18:
    case 19:
    case 20:
      TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
      TRY(cardano_reward_address_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &reward));
      if (tag == 18)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &number));
        cardano_tx_builder_add_direct_deposit(builder, reward, number);
      }
      else
      {
        TRY(read_interval(reader, &interval));
        if (tag == 19)
        {
          cardano_tx_builder_add_account_balance_interval(builder, reward, interval);
        }
        else
        {
          cardano_tx_builder_add_starting_account_balance_interval(builder, reward, interval);
        }
      }
      break;
    case 21:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      cardano_tx_builder_set_donation(builder, number);
      break;
    case 22:
      TRY(read_proposal(reader, &proposal));
      TRY(apply_proposal(builder, proposal));
      break;
    case 23:
    case 24:
      TRY(read_voter(reader, &voter));
      TRY(read_action_id(reader, &action_id));
      TRY(read_procedure(reader, &procedure));
      if (tag == 24)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &context->index));
        bool registered = false;
        for (size_t i = 0; i < position; ++i)
        {
          if (contexts[i].deferred_vote && contexts[i].index == context->index)
          {
            registered = true;
          }
        }
        context->deferred_vote = true;
        if (registered)
        {
          cardano_tx_builder_vote(builder, voter, action_id, procedure, NULL);
        }
        else
        {
          cardano_tx_builder_vote_with_deferred_redeemer(builder, voter, action_id, procedure, deferred_callback, context);
        }
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_tx_builder_vote(builder, voter, action_id, procedure, redeemer);
      }
      break;
    case 25:
      TRY(read_sub(reader, &sub));
      TRY(read_utxos(reader, &sub_resolved));
      for (size_t i = 0; i < cardano_utxo_list_get_length(sub_resolved); ++i)
      {
        cardano_utxo_t* item = NULL;
        result               = cardano_utxo_list_get(sub_resolved, i, &item);
        if (result == CARDANO_SUCCESS)
        {
          result = cardano_utxo_list_add(resolved, item);
        }
        cardano_utxo_unref(&item);
        if (result != CARDANO_SUCCESS)
        {
          goto cleanup;
        }
      }
      cardano_tx_builder_add_sub_transaction(builder, sub, sub_resolved);
      break;
    default:
      result = CARDANO_ERROR_DECODING;
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_end_array(reader);
  }
cleanup:
  cardano_credential_unref(&credential);
  cardano_account_balance_interval_unref(&interval);
  cardano_proposal_procedure_unref(&proposal);
  cardano_voter_unref(&voter);
  cardano_governance_action_id_unref(&action_id);
  cardano_voting_procedure_unref(&procedure);
  cardano_sub_transaction_unref(&sub);
  cardano_utxo_list_unref(&sub_resolved);
  cardano_transaction_output_unref(&output);
  cardano_utxo_unref(&utxo);
  cardano_script_unref(&script);
  cardano_plutus_data_unref(&redeemer);
  cardano_plutus_data_unref(&datum);
  cardano_certificate_unref(&certificate);
  cardano_metadatum_unref(&metadata);
  cardano_blake2b_hash_unref(&hash);
  cardano_asset_name_unref(&asset_name);
  cardano_reward_address_unref(&reward);
  cardano_buffer_unref(&bytes);
  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_transaction_builder_build(cometa_runtime_t* selector_runtime, cometa_runtime_t* evaluator_runtime, cometa_runtime_t* deferred_runtime, const unsigned char* config, size_t config_size, const unsigned char* plan, size_t plan_size, cardano_buffer_t** output, cardano_buffer_t** diagnostic, uint64_t* key_count)
{
  if (output == NULL || diagnostic == NULL || key_count == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }
  *key_count                                       = 0U;
  *output                                          = NULL;
  *diagnostic                                      = NULL;
  cardano_cbor_reader_t*         reader            = cardano_cbor_reader_new(config, config_size);
  cardano_cbor_reader_t*         instructions      = NULL;
  cardano_cbor_writer_t*         writer            = NULL;
  cardano_buffer_t*              parameter_bytes   = NULL;
  cardano_protocol_parameters_t* parameters        = NULL;
  cardano_address_t*             change            = NULL;
  cardano_address_t*             collateral_change = NULL;
  cardano_utxo_list_t*           available         = NULL;
  cardano_utxo_list_t*           collateral        = NULL;
  cardano_utxo_list_t*           resolved          = NULL;
  cardano_blake2b_hash_set_t*    unique_signers    = NULL;
  cardano_tx_builder_t*          builder           = NULL;
  cardano_transaction_t*         transaction       = NULL;
  cardano_coin_selector_t*       selector          = NULL;
  cardano_tx_evaluator_t*        evaluator         = NULL;
  uint64_t                       fee = 0U, padding = 0U;
  cardano_slot_config_t          slots    = { 0 };
  int64_t                        count    = 0;
  deferred_context_t*            contexts = NULL;
  cardano_network_id_t           network;
  cardano_error_t                result = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : array(reader, 10);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  TRY(cardano_cbor_reader_read_bytestring(reader, &parameter_bytes));
  TRY(cometa_parameters_from_snapshot(cardano_buffer_get_data(parameter_bytes), cardano_buffer_get_size(parameter_bytes), &parameters));
  TRY(read_address(reader, &change));
  TRY(read_utxos(reader, &available));
  TRY(read_utxos(reader, &collateral));
  TRY(read_address(reader, &collateral_change));
  TRY(cardano_cbor_reader_read_uint(reader, &fee));
  TRY(cardano_cbor_reader_read_uint(reader, &padding));
  TRY(cardano_cbor_reader_read_uint(reader, &slots.zero_time));
  TRY(cardano_cbor_reader_read_uint(reader, &slots.zero_slot));
  TRY(cardano_cbor_reader_read_uint(reader, &slots.slot_length));
  TRY(cardano_cbor_reader_read_end_array(reader));
  TRY(complete(reader));
  if (slots.slot_length == 0U || padding > SIZE_MAX)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  builder = cardano_tx_builder_new(parameters, &slots);
  if (builder == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  TRY(cardano_address_get_network_id(change, &network));
  cardano_tx_builder_set_network_id(builder, network);
  cardano_tx_builder_set_change_address(builder, change);
  cardano_tx_builder_set_utxos(builder, available);
  cardano_tx_builder_set_collateral_utxos(builder, collateral);
  cardano_tx_builder_set_collateral_change_address(builder, collateral_change != NULL ? collateral_change : change);
  cardano_tx_builder_set_minimum_fee(builder, fee);
  cardano_tx_builder_pad_signer_count(builder, (size_t)padding);
  if (selector_runtime != NULL)
  {
    TRY(cometa_coin_selector_new(selector_runtime, cardano_buffer_get_data(parameter_bytes), cardano_buffer_get_size(parameter_bytes), &selector));
    cardano_tx_builder_set_coin_selector(builder, selector);
  }
  if (evaluator_runtime != NULL)
  {
    TRY(cometa_evaluation_new(evaluator_runtime, &evaluator));
    cardano_tx_builder_set_tx_evaluator(builder, evaluator);
  }
  TRY(cardano_utxo_list_new(&resolved));
  for (size_t i = 0; i < cardano_utxo_list_get_length(available) + cardano_utxo_list_get_length(collateral); ++i)
  {
    cardano_utxo_t* item   = NULL;
    const size_t    offset = cardano_utxo_list_get_length(available);
    result                 = i < offset ? cardano_utxo_list_get(available, i, &item) : cardano_utxo_list_get(collateral, i - offset, &item);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_utxo_list_add(resolved, item);
    }
    cardano_utxo_unref(&item);
    if (result != CARDANO_SUCCESS)
    {
      goto cleanup;
    }
  }
  instructions = cardano_cbor_reader_new(plan, plan_size);
  if (instructions == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  TRY(cardano_cbor_reader_read_start_array(instructions, &count));
  if (count < 0)
  {
    result = CARDANO_ERROR_DECODING;
    goto cleanup;
  }
  if ((uint64_t)count > SIZE_MAX / sizeof(deferred_context_t))
  {
    result = CARDANO_ERROR_INTEGER_OVERFLOW;
    goto cleanup;
  }
  contexts = calloc(count == 0 ? 1U : (size_t)count, sizeof(deferred_context_t));
  if (contexts == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  for (int64_t i = 0; i < count; ++i)
  {
    contexts[i].runtime = deferred_runtime;
    TRY(instruction(builder, instructions, resolved, contexts, (size_t)i));
  }
  TRY(cardano_cbor_reader_read_end_array(instructions));
  TRY(complete(instructions));
  TRY(cardano_tx_builder_build(builder, &transaction));
  TRY(cardano_transaction_get_unique_signers(transaction, resolved, &unique_signers));
  if ((uint64_t)cardano_blake2b_hash_set_get_length(unique_signers) > UINT64_MAX - padding)
  {
    result = CARDANO_ERROR_INTEGER_OVERFLOW;
    goto cleanup;
  }
  *key_count = (uint64_t)cardano_blake2b_hash_set_get_length(unique_signers) + padding;
  writer     = cardano_cbor_writer_new();
  if (writer == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  TRY(cardano_transaction_to_cbor(transaction, writer));
  TRY(cardano_cbor_writer_encode_in_buffer(writer, output));
cleanup:
  if (result != CARDANO_SUCCESS && builder != NULL)
  {
    const char* message = cardano_tx_builder_get_last_error(builder);
    if (message != NULL && message[0] != '\0')
    {
      *diagnostic = cardano_buffer_new_from((const byte_t*)message, strlen(message));
    }
  }
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_reader_unref(&instructions);
  cardano_blake2b_hash_set_unref(&unique_signers);
  cardano_utxo_list_unref(&resolved);
  cardano_tx_builder_unref(&builder);
  free(contexts);
  cardano_transaction_unref(&transaction);
  cardano_coin_selector_unref(&selector);
  cardano_tx_evaluator_unref(&evaluator);
  cardano_protocol_parameters_unref(&parameters);
  cardano_address_unref(&change);
  cardano_address_unref(&collateral_change);
  cardano_utxo_list_unref(&available);
  cardano_utxo_list_unref(&collateral);
  cardano_buffer_unref(&parameter_bytes);
  return result;
}

#undef TRY
