/**
 * \file cometa_sub_transaction_builder.c
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

#include "cometa_sub_transaction_builder.h"
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
#undef READ_OBJECT

/** \brief Copy the local fee-zero draft into the protected callback and transfer its argument. */
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

/** \brief Apply one instruction, releasing local references after builder retention. */
static cardano_error_t
instruction(cardano_sub_tx_builder_t* builder, cardano_cbor_reader_t* reader, cardano_utxo_list_t* resolved, deferred_context_t* contexts, size_t position)
{
  deferred_context_t*                 context   = &contexts[position];
  static const int64_t                arities[] = { 2, 4, 2, 2, 5, 3, 2, 3, 4, 2, 2, 2, 4, 5, 3, 4, 3, 0, 3, 3, 3, 2, 3, 5, 5, 3, 3, 0, 3 };
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
  cardano_buffer_t*                   bytes         = NULL;
  cardano_error_t                     result        = cardano_cbor_reader_read_start_array(reader, &count);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_uint(reader, &tag);
  }
  if (result == CARDANO_SUCCESS && (tag >= sizeof(arities) / sizeof(arities[0]) || tag == 17 || tag == 20 || tag == 25 || count != arities[tag]))
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
      cardano_sub_tx_builder_add_output(builder, output);
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
        cardano_sub_tx_builder_add_input_with_deferred_redeemer(builder, utxo, deferred_callback, context, datum);
      }
      else
      {
        cardano_sub_tx_builder_add_input(builder, utxo, redeemer, datum);
      }
      break;
    case 2:
      TRY(read_utxo(reader, &utxo));
      TRY(cardano_utxo_list_add(resolved, utxo));
      cardano_sub_tx_builder_add_reference_input(builder, utxo);
      break;
    case 3:
      TRY(read_script(reader, &script));
      cardano_sub_tx_builder_add_script(builder, script);
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
          cardano_sub_tx_builder_mint_token(builder, hash, asset_name, signed_number, NULL);
        }
        else
        {
          cardano_sub_tx_builder_mint_token_with_deferred_redeemer(builder, hash, asset_name, signed_number, deferred_callback, context);
        }
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_sub_tx_builder_mint_token(builder, hash, asset_name, signed_number, redeemer);
      }
      break;
    case 5:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      TRY(read_metadata(reader, &metadata));
      cardano_sub_tx_builder_set_metadata(builder, number, metadata);
      break;
    case 6:
      TRY(read_data(reader, &datum));
      cardano_sub_tx_builder_add_datum(builder, datum);
      break;
    case 14:
    case 7:
      TRY(read_certificate(reader, &certificate));
      if (tag == 14)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &context->index));
        cardano_sub_tx_builder_add_certificate_with_deferred_redeemer(builder, certificate, deferred_callback, context);
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_sub_tx_builder_add_certificate(builder, certificate, redeemer);
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
        cardano_sub_tx_builder_withdraw_rewards_with_deferred_redeemer(builder, reward, (int64_t)number, deferred_callback, context);
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_sub_tx_builder_withdraw_rewards(builder, reward, (int64_t)number, redeemer);
      }
      break;
    case 9:
      TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
      TRY(cardano_blake2b_hash_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &hash));
      cardano_sub_tx_builder_add_signer(builder, hash);
      break;
    case 10:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      cardano_sub_tx_builder_set_invalid_before(builder, number);
      break;
    case 11:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      cardano_sub_tx_builder_set_invalid_after(builder, number);
      break;
    case 16:
      TRY(read_credential(reader, &credential));
      TRY(read_data(reader, &redeemer));
      if (redeemer == NULL)
      {
        cardano_sub_tx_builder_add_guard(builder, credential);
      }
      else
      {
        cardano_sub_tx_builder_add_guard_with_redeemer(builder, credential, redeemer);
      }
      break;
    case 18:
    case 19:
      TRY(cardano_cbor_reader_read_bytestring(reader, &bytes));
      TRY(cardano_reward_address_from_bytes(cardano_buffer_get_data(bytes), cardano_buffer_get_size(bytes), &reward));
      if (tag == 18)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &number));
        cardano_sub_tx_builder_add_direct_deposit(builder, reward, number);
      }
      else
      {
        TRY(read_interval(reader, &interval));
        cardano_sub_tx_builder_add_account_balance_interval(builder, reward, interval);
      }
      break;
    case 21:
      TRY(cardano_cbor_reader_read_uint(reader, &number));
      cardano_sub_tx_builder_set_donation(builder, number);
      break;
    case 22:
    case 28:
      TRY(read_proposal(reader, &proposal));
      if (tag == 28U)
      {
        TRY(cardano_cbor_reader_read_uint(reader, &context->index));
        cardano_sub_tx_builder_add_proposal_with_deferred_redeemer(builder, proposal, deferred_callback, context);
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_sub_tx_builder_add_proposal(builder, proposal, redeemer);
      }
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
          cardano_sub_tx_builder_vote(builder, voter, action_id, procedure, NULL);
        }
        else
        {
          cardano_sub_tx_builder_vote_with_deferred_redeemer(builder, voter, action_id, procedure, deferred_callback, context);
        }
      }
      else
      {
        TRY(read_data(reader, &redeemer));
        cardano_sub_tx_builder_vote(builder, voter, action_id, procedure, redeemer);
      }
      break;
    case 26:
      TRY(read_credential(reader, &credential));
      TRY(read_data(reader, &datum));
      cardano_sub_tx_builder_require_top_level_guard(builder, credential, datum);
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
cometa_sub_transaction_builder_build(cometa_runtime_t* deferred_runtime, const unsigned char* config, size_t config_size, const unsigned char* plan, size_t plan_size, cardano_buffer_t** output, cardano_buffer_t** diagnostic)
{
  if (output != NULL)
  {
    *output = NULL;
  }
  if (diagnostic != NULL)
  {
    *diagnostic = NULL;
  }
  if (deferred_runtime == NULL || config == NULL || plan == NULL || output == NULL || diagnostic == NULL)
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }
  cardano_cbor_reader_t*         reader          = cardano_cbor_reader_new(config, config_size);
  cardano_cbor_reader_t*         instructions    = NULL;
  cardano_cbor_writer_t*         writer          = NULL;
  cardano_buffer_t*              parameter_bytes = NULL;
  cardano_protocol_parameters_t* parameters      = NULL;
  cardano_utxo_list_t*           resolved        = NULL;
  cardano_sub_tx_builder_t*      builder         = NULL;
  cardano_sub_transaction_t*     transaction     = NULL;
  deferred_context_t*            contexts        = NULL;
  cardano_slot_config_t          slots           = { 0 };
  uint64_t                       network         = 0U;
  int64_t                        count           = 0;
  cardano_error_t                result          = reader == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : array(reader, 5);
  if (result != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  TRY(cardano_cbor_reader_read_bytestring(reader, &parameter_bytes));
  TRY(cometa_parameters_from_snapshot(cardano_buffer_get_data(parameter_bytes), cardano_buffer_get_size(parameter_bytes), &parameters));
  TRY(cardano_cbor_reader_read_uint(reader, &network));
  TRY(cardano_cbor_reader_read_uint(reader, &slots.zero_time));
  TRY(cardano_cbor_reader_read_uint(reader, &slots.zero_slot));
  TRY(cardano_cbor_reader_read_uint(reader, &slots.slot_length));
  TRY(cardano_cbor_reader_read_end_array(reader));
  TRY(complete(reader));
  if (slots.slot_length == 0U || network > 1U)
  {
    result = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }
  builder = cardano_sub_tx_builder_new(parameters, &slots);
  if (builder == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  cardano_sub_tx_builder_set_network_id(builder, (cardano_network_id_t)network);
  TRY(cardano_utxo_list_new(&resolved));
  instructions = cardano_cbor_reader_new(plan, plan_size);
  if (instructions == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  TRY(cardano_cbor_reader_read_start_array(instructions, &count));
  if (count < 0 || (uint64_t)count > SIZE_MAX / sizeof(deferred_context_t))
  {
    result = CARDANO_ERROR_DECODING;
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
  TRY(cardano_sub_tx_builder_build(builder, &transaction));
  writer = cardano_cbor_writer_new();
  if (writer == NULL)
  {
    result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    goto cleanup;
  }
  TRY(cardano_sub_transaction_to_cbor(transaction, writer));
  TRY(cardano_cbor_writer_encode_in_buffer(writer, output));
cleanup:
  if (result != CARDANO_SUCCESS)
  {
    const char* message = builder != NULL ? cardano_sub_tx_builder_get_last_error(builder) : cardano_error_to_string(result);
    if (message == NULL || message[0] == '\0')
    {
      message = cardano_error_to_string(result);
    }
    *diagnostic = cardano_buffer_new_from((const byte_t*)message, strlen(message));
    cardano_buffer_unref(output);
    *output = NULL;
  }
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  cardano_cbor_reader_unref(&instructions);
  cardano_utxo_list_unref(&resolved);
  cardano_sub_tx_builder_unref(&builder);
  free(contexts);
  cardano_sub_transaction_unref(&transaction);
  cardano_protocol_parameters_unref(&parameters);
  cardano_buffer_unref(&parameter_bytes);
  return result;
}

#undef TRY
