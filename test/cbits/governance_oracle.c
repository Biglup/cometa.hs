/**
 * \file governance_oracle.c
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
#include <stdlib.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/**
 * \brief Reconstructs an anchor from borrowed field snapshots. The output is
 * owned by the caller; all input memory stays owned by source through return.
 */
static cardano_error_t
rebuild_anchor(cardano_anchor_t* source, cardano_anchor_t** output)
{
  const char* location = cardano_anchor_get_url(source);
  return cardano_anchor_from_hash_bytes(
    location, strlen(location), cardano_anchor_get_hash_bytes(source), cardano_anchor_get_hash_bytes_size(source), output);
}

/** \brief Reconstructs a proposal identity from its hash and full uint64 index. */
static cardano_error_t
rebuild_action(cardano_governance_action_id_t* source, cardano_governance_action_id_t** output)
{
  uint64_t        index  = 0;
  cardano_error_t result = cardano_governance_action_id_get_index(source, &index);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_governance_action_id_from_hash_bytes(
      cardano_governance_action_id_get_hash_bytes(source),
      cardano_governance_action_id_get_hash_bytes_size(source),
      index,
      output);
  }
  return result;
}

/** \brief Reconstructs a voter. The credential getter retains its result. */
static cardano_error_t
rebuild_voter(cardano_voter_t* source, cardano_voter_t** output)
{
  cardano_voter_type_t  type       = CARDANO_VOTER_TYPE_CONSTITUTIONAL_COMMITTEE_KEY_HASH;
  cardano_credential_t* credential = cardano_voter_get_credential(source);
  cardano_error_t       result     = cardano_voter_get_type(source, &type);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_voter_new(type, credential, output);
  }
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs a DRep, retaining a credential only for credential kinds. */
static cardano_error_t
rebuild_drep(cardano_drep_t* source, cardano_drep_t** output)
{
  cardano_drep_type_t   type       = CARDANO_DREP_TYPE_KEY_HASH;
  cardano_credential_t* credential = NULL;
  cardano_error_t       result     = cardano_drep_get_type(source, &type);
  if ((result == CARDANO_SUCCESS) && ((type == CARDANO_DREP_TYPE_KEY_HASH) || (type == CARDANO_DREP_TYPE_SCRIPT_HASH)))
  {
    result = cardano_drep_get_credential(source, &credential);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_drep_new(type, credential, output);
  }
  cardano_credential_unref(&credential);
  return result;
}

/** \brief Reconstructs a choice and optional anchor; both anchor locals own refs. */
static cardano_error_t
rebuild_procedure(cardano_voting_procedure_t* source, cardano_voting_procedure_t** output)
{
  cardano_anchor_t* anchor       = cardano_voting_procedure_get_anchor(source);
  cardano_anchor_t* fresh_anchor = NULL;
  cardano_error_t   result       = CARDANO_SUCCESS;
  if (anchor != NULL)
  {
    result = rebuild_anchor(anchor, &fresh_anchor);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_voting_procedure_new(cardano_voting_procedure_get_vote(source), fresh_anchor, output);
  }
  cardano_anchor_unref(&fresh_anchor);
  cardano_anchor_unref(&anchor);
  return result;
}

/**
 * \brief Rebuilds one voter's actions by getter snapshots and insertion.
 * Getter outputs are retained references. Released loop locals are nulled even
 * when another native owner keeps the underlying object alive.
 */
static cardano_error_t
rebuild_actions(cardano_voting_procedures_t* source, cardano_voter_t* voter, cardano_voting_procedures_t* output)
{
  cardano_governance_action_id_list_t* actions         = NULL;
  cardano_governance_action_id_t*      action          = NULL;
  cardano_governance_action_id_t*      fresh_action    = NULL;
  cardano_voter_t*                     fresh_voter     = NULL;
  cardano_voting_procedure_t*          procedure       = NULL;
  cardano_voting_procedure_t*          fresh_procedure = NULL;
  cardano_error_t                      result          = cardano_voting_procedures_get_governance_ids_by_voter(source, voter, &actions);
  if (result == CARDANO_SUCCESS)
  {
    result = rebuild_voter(voter, &fresh_voter);
  }
  for (size_t i = 0; (result == CARDANO_SUCCESS) && (i < cardano_governance_action_id_list_get_length(actions)); ++i)
  {
    result = cardano_governance_action_id_list_get(actions, i, &action);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_action(action, &fresh_action);
    }
    if (result == CARDANO_SUCCESS)
    {
      procedure = cardano_voting_procedures_get(source, voter, action);
      result    = procedure == NULL ? CARDANO_ERROR_ELEMENT_NOT_FOUND : rebuild_procedure(procedure, &fresh_procedure);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_voting_procedures_insert(output, fresh_voter, fresh_action, fresh_procedure);
    }
    cardano_voting_procedure_unref(&fresh_procedure);
    fresh_procedure = NULL;
    cardano_voting_procedure_unref(&procedure);
    procedure = NULL;
    cardano_governance_action_id_unref(&fresh_action);
    fresh_action = NULL;
    cardano_governance_action_id_unref(&action);
    action = NULL;
  }
  cardano_voter_unref(&fresh_voter);
  cardano_governance_action_id_list_unref(&actions);
  return result;
}

/** \brief Reconstructs the entire unique voting map, including native sort order. */
static cardano_error_t
rebuild_voting(cardano_voting_procedures_t* source, cardano_voting_procedures_t** output)
{
  cardano_voter_list_t* voters = NULL;
  cardano_voter_t*      voter  = NULL;
  cardano_error_t       result = cardano_voting_procedures_new(output);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_voting_procedures_get_voters(source, &voters);
  }
  for (size_t i = 0; (result == CARDANO_SUCCESS) && (i < cardano_voter_list_get_length(voters)); ++i)
  {
    result = cardano_voter_list_get(voters, i, &voter);
    if (result == CARDANO_SUCCESS)
    {
      result = rebuild_actions(source, voter, *output);
    }
    cardano_voter_unref(&voter);
    voter = NULL;
  }
  cardano_voter_list_unref(&voters);
  return result;
}

/* DEFINITIONS ***************************************************************/

/**
 * \brief Checks typed Haskell assembly against native semantic reconstruction.
 * mode 0=anchor, 1=action, 2=DRep, 3=voter, 4=procedure, 5=voting map.
 * Inputs are borrowed through return. Every native owner is released locally;
 * reconstructed values are serialized without forwarding cached source bytes.
 */
int
cometa_test_governance_agreement(unsigned int mode, const unsigned char* input, size_t size)
{
  cardano_cbor_reader_t* reader  = cardano_cbor_reader_new(input, size);
  cardano_cbor_writer_t* writer  = cardano_cbor_writer_new();
  cardano_buffer_t*      encoded = NULL;
  cardano_error_t        result  = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  int                    agrees  = 0;
  if ((reader == NULL) || (writer == NULL))
  {
    goto cleanup;
  }
  switch (mode)
  {
    case 0:
    {
      cardano_anchor_t* source = NULL;
      cardano_anchor_t* fresh  = NULL;
      result                   = cardano_anchor_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_anchor(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_anchor_to_cbor(fresh, writer);
      }
      cardano_anchor_unref(&fresh);
      cardano_anchor_unref(&source);
      break;
    }
    case 1:
    {
      cardano_governance_action_id_t* source = NULL;
      cardano_governance_action_id_t* fresh  = NULL;
      result                                 = cardano_governance_action_id_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_action(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_governance_action_id_to_cbor(fresh, writer);
      }
      cardano_governance_action_id_unref(&fresh);
      cardano_governance_action_id_unref(&source);
      break;
    }
    case 2:
    {
      cardano_drep_t* source = NULL;
      cardano_drep_t* fresh  = NULL;
      result                 = cardano_drep_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_drep(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_drep_to_cbor(fresh, writer);
      }
      cardano_drep_unref(&fresh);
      cardano_drep_unref(&source);
      break;
    }
    case 3:
    {
      cardano_voter_t* source = NULL;
      cardano_voter_t* fresh  = NULL;
      result                  = cardano_voter_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_voter(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_voter_to_cbor(fresh, writer);
      }
      cardano_voter_unref(&fresh);
      cardano_voter_unref(&source);
      break;
    }
    case 4:
    {
      cardano_voting_procedure_t* source = NULL;
      cardano_voting_procedure_t* fresh  = NULL;
      result                             = cardano_voting_procedure_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_procedure(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_voting_procedure_to_cbor(fresh, writer);
      }
      cardano_voting_procedure_unref(&fresh);
      cardano_voting_procedure_unref(&source);
      break;
    }
    case 5:
    {
      cardano_voting_procedures_t* source = NULL;
      cardano_voting_procedures_t* fresh  = NULL;
      result                              = cardano_voting_procedures_from_cbor(reader, &source);
      if (result == CARDANO_SUCCESS)
      {
        result = rebuild_voting(source, &fresh);
      }
      if (result == CARDANO_SUCCESS)
      {
        result = cardano_voting_procedures_to_cbor(fresh, writer);
      }
      cardano_voting_procedures_unref(&fresh);
      cardano_voting_procedures_unref(&source);
      break;
    }
    default:
    {
      result = CARDANO_ERROR_INVALID_ARGUMENT;
      break;
    }
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, &encoded);
  }
  if (result == CARDANO_SUCCESS)
  {
    agrees = (cardano_buffer_get_size(encoded) == size) && (memcmp(cardano_buffer_get_data(encoded), input, size) == 0);
  }
cleanup:
  cardano_buffer_unref(&encoded);
  cardano_cbor_writer_unref(&writer);
  cardano_cbor_reader_unref(&reader);
  return agrees;
}
