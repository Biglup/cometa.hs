/**
 * \file cometa_transaction.c
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

#include "cometa_transaction.h"
#include <cardano/buffer.h>
#include <cardano/cbor/cbor_reader.h>
#include <cardano/cbor/cbor_writer.h>
#include <cardano/transaction/transaction.h>
#include <stdlib.h>

/* TYPES *********************************************************************/

struct cometa_transaction_snapshot_t
{
    cardano_buffer_t*       full;
    cardano_buffer_t*       body;
    cardano_buffer_t*       witnesses;
    cardano_blake2b_hash_t* hash;
    uint64_t                fee;
};

/* STATIC FUNCTIONS **********************************************************/

/** \brief Decode a complete frame; no reader or partial transaction escapes failure. */
static cardano_error_t
decode_transaction(const unsigned char* data, size_t size, cardano_transaction_t** transaction)
{
  *transaction = NULL;

  if ((data == NULL) || (size == 0U))
  {
    return CARDANO_ERROR_DECODING;
  }

  cardano_cbor_reader_t* reader = cardano_cbor_reader_new(data, size);
  if (reader == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  cardano_error_t result    = cardano_transaction_from_cbor(reader, transaction);
  size_t          remaining = 0U;
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_get_bytes_remaining(reader, &remaining);
    if ((result == CARDANO_SUCCESS) && ((*transaction == NULL) || (remaining != 0U)))
    {
      result = CARDANO_ERROR_DECODING;
    }
  }

  cardano_cbor_reader_unref(&reader);
  if (result != CARDANO_SUCCESS)
  {
    cardano_transaction_unref(transaction);
    *transaction = NULL;
  }

  return result;
}

/** \brief Extract original body/witness spans from an already validated frame. */
static cardano_error_t
snapshot_parts(const unsigned char* data, size_t size, cometa_transaction_snapshot_t* snapshot)
{
  cardano_cbor_reader_t* reader = cardano_cbor_reader_new(data, size);
  if (reader == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  int64_t         frame_size = 0;
  cardano_error_t result     = cardano_cbor_reader_read_start_array(reader, &frame_size);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_encoded_value(reader, &snapshot->body);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_reader_read_encoded_value(reader, &snapshot->witnesses);
  }

  cardano_cbor_reader_unref(&reader);
  return result;
}

/** \brief Snapshot owned buffers/hash, releasing the complete partial result on failure. */
static cardano_error_t
snapshot_transaction(cardano_transaction_t* transaction, const unsigned char* data, size_t size, cometa_transaction_snapshot_t** output)
{
  cometa_transaction_snapshot_t* snapshot = calloc(1U, sizeof(cometa_transaction_snapshot_t));
  if (snapshot == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  snapshot->full         = cardano_buffer_new_from(data, size);
  cardano_error_t result = snapshot->full == NULL ? CARDANO_ERROR_MEMORY_ALLOCATION_FAILED : snapshot_parts(data, size, snapshot);
  if (result == CARDANO_SUCCESS)
  {
    snapshot->hash                   = cardano_transaction_get_id(transaction);
    cardano_transaction_body_t* body = cardano_transaction_get_body(transaction);
    if ((snapshot->hash == NULL) || (body == NULL))
    {
      result = CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
    }
    else
    {
      snapshot->fee = cardano_transaction_body_get_fee(body);
    }
    cardano_transaction_body_unref(&body);
  }
  if (result != CARDANO_SUCCESS)
  {
    cometa_transaction_snapshot_free(&snapshot);
    return result;
  }

  *output = snapshot;
  return CARDANO_SUCCESS;
}

/** \brief Modify an independent native clone; leave source caches and witnesses untouched. */
static cardano_error_t
edit_fee(cardano_transaction_t* source, uint64_t fee, cardano_transaction_t** copy)
{
  cardano_error_t result = cardano_transaction_deep_clone(source, copy);
  if (result != CARDANO_SUCCESS)
  {
    return result;
  }

  cardano_transaction_body_t* body      = cardano_transaction_get_body(*copy);
  cardano_witness_set_t*      witnesses = cardano_transaction_get_witness_set(*copy);
  if ((body == NULL) || (witnesses == NULL))
  {
    result = CARDANO_ERROR_DECODING;
  }
  else
  {
    result = cardano_transaction_body_set_fee(body, fee);
    cardano_transaction_body_clear_cbor_cache(body);
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_witness_set_set_vkeys(witnesses, NULL);
    }
    if (result == CARDANO_SUCCESS)
    {
      result = cardano_witness_set_set_bootstrap(witnesses, NULL);
    }
  }

  cardano_witness_set_unref(&witnesses);
  cardano_transaction_body_unref(&body);
  return result;
}

/** \brief Materialize a transaction into one owned native byte buffer. */
static cardano_error_t
encode_transaction(cardano_transaction_t* transaction, cardano_buffer_t** encoded)
{
  cardano_cbor_writer_t* writer = cardano_cbor_writer_new();
  if (writer == NULL)
  {
    return CARDANO_ERROR_MEMORY_ALLOCATION_FAILED;
  }

  cardano_error_t result = cardano_transaction_to_cbor(transaction, writer);
  if (result == CARDANO_SUCCESS)
  {
    result = cardano_cbor_writer_encode_in_buffer(writer, encoded);
  }

  cardano_cbor_writer_unref(&writer);
  return result;
}

/* DEFINITIONS ***************************************************************/

unsigned int
cometa_transaction_decode(const unsigned char* data, size_t size, cometa_transaction_snapshot_t** snapshot)
{
  if (snapshot == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }

  *snapshot                          = NULL;
  cardano_transaction_t* transaction = NULL;
  cardano_error_t        result      = decode_transaction(data, size, &transaction);
  if (result == CARDANO_SUCCESS)
  {
    result = snapshot_transaction(transaction, data, size, snapshot);
  }

  cardano_transaction_unref(&transaction);
  return (unsigned int)result;
}

unsigned int
cometa_transaction_set_fee(const unsigned char* data, size_t size, uint64_t fee, cometa_transaction_snapshot_t** snapshot)
{
  if (snapshot == NULL)
  {
    return (unsigned int)CARDANO_ERROR_POINTER_IS_NULL;
  }

  *snapshot                      = NULL;
  cardano_transaction_t* source  = NULL;
  cardano_transaction_t* copy    = NULL;
  cardano_buffer_t*      encoded = NULL;
  cardano_error_t        result  = decode_transaction(data, size, &source);
  if (result == CARDANO_SUCCESS)
  {
    result = edit_fee(source, fee, &copy);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = encode_transaction(copy, &encoded);
  }
  if (result == CARDANO_SUCCESS)
  {
    result = snapshot_transaction(copy, cardano_buffer_get_data(encoded), cardano_buffer_get_size(encoded), snapshot);
  }

  cardano_buffer_unref(&encoded);
  cardano_transaction_unref(&copy);
  cardano_transaction_unref(&source);
  return (unsigned int)result;
}

void
cometa_transaction_snapshot_free(cometa_transaction_snapshot_t** snapshot)
{
  if ((snapshot == NULL) || (*snapshot == NULL))
  {
    return;
  }

  cardano_buffer_unref(&(*snapshot)->full);
  cardano_buffer_unref(&(*snapshot)->body);
  cardano_buffer_unref(&(*snapshot)->witnesses);
  cardano_blake2b_hash_unref(&(*snapshot)->hash);
  free(*snapshot);
  *snapshot = NULL;
}

const unsigned char*
cometa_transaction_snapshot_bytes(const cometa_transaction_snapshot_t* snapshot, unsigned int field, size_t* size)
{
  if (size == NULL)
  {
    return NULL;
  }

  *size = 0U;
  if (snapshot == NULL)
  {
    return NULL;
  }

  if (field == 2U)
  {
    *size = cardano_blake2b_hash_get_bytes_size(snapshot->hash);
    return cardano_blake2b_hash_get_data(snapshot->hash);
  }

  const cardano_buffer_t* buffer = field == 0U ? snapshot->full : field == 1U ? snapshot->body
    : field == 3U                                                             ? snapshot->witnesses
                                                                              : NULL;
  *size                          = cardano_buffer_get_size(buffer);
  return cardano_buffer_get_data(buffer);
}

uint64_t
cometa_transaction_snapshot_fee(const cometa_transaction_snapshot_t* snapshot)
{
  return snapshot == NULL ? 0U : snapshot->fee;
}
