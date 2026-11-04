/**
 * \file cometa_cbor.h
 *
 * \author angel.castillo
 * \date   Nov 04, 2026
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

#ifndef BIGLUP_LABS_INCLUDE_COMETA_CBOR_H
#define BIGLUP_LABS_INCLUDE_COMETA_CBOR_H

/* INCLUDES ******************************************************************/

#include <cardano/buffer.h>
#include <cardano/cbor/cbor_reader.h>
#include <stddef.h>
#include <stdint.h>

/* DECLARATIONS **************************************************************/

#ifdef __cplusplus
extern "C" {
#endif /* __cplusplus */

/**
 * \brief Private, synchronous CBOR adapters with an explicit unsigned status ABI.
 *
 * Data, readers, diagnostic buffers and output slots must be non-NULL unless their function contract
 * states otherwise. Diagnostic pointers may be NULL to disable copying. Every status-returning function returns a cardano-c status converted to unsigned int.
 * Diagnostic capacities count bytes including the terminator; zero capacity disables diagnostic copying.
 * Output references are initialized to NULL and belong to the caller even on a partial failure.
 * The caller must keep input storage and output slots valid until the complete synchronous call returns.
 */

/**
 * \brief Validates exactly one native-reader-accepted item. Input is borrowed; diagnostics are copied before reader release.
 *
 * \param[in] data Borrowed bytes kept valid until the call returns.
 * \param[in] size Number of bytes available at data.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_validate(const unsigned char* data, size_t size, char* error, size_t error_size);

/**
 * \brief Encodes a primitive integer. A negative argument represents -1 minus argument. Output owns one buffer reference.
 *
 * \param[in] negative Zero selects unsigned encoding; nonzero selects negative encoding.
 * \param[in] argument Unsigned value, or the argument in the negative value -1 - argument.
 * \param[out] output Receives one owned reference, including any partial result on failure.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_encode_integer(int negative, uint64_t argument, cardano_buffer_t** output, char* error, size_t error_size);

/**
 * \brief Reads an untagged primitive integer into an exact sign and unsigned magnitude argument.
 *
 * \param[in] data Borrowed bytes kept valid until the call returns.
 * \param[in] size Number of bytes available at data.
 * \param[out] negative Receives 1 for a negative integer and 0 for an unsigned integer.
 * \param[out] argument Receives the unsigned integer or the argument in the value -1 - argument.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_decode_integer(const unsigned char* data, size_t size, int* negative, uint64_t* argument, char* error, size_t error_size);

/**
 * \brief Encodes borrowed bytes as a byte string or UTF-8 text string. Output owns one buffer reference.
 *
 * \param[in] text Zero selects a byte string; nonzero selects a text string.
 * \param[in] data Borrowed bytes kept valid until the call returns.
 * \param[in] size Number of bytes available at data.
 * \param[out] output Receives one owned reference, including any partial result on failure.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_encode_string(int text, const unsigned char* data, size_t size, cardano_buffer_t** output, char* error, size_t error_size);

/**
 * \brief Reads a byte or text string into one owned buffer, flattening indefinite chunks. UTF-8 validation belongs to Haskell.
 *
 * \param[in] text Zero selects a byte string; nonzero selects a text string.
 * \param[in] data Borrowed bytes kept valid until the call returns.
 * \param[in] size Number of bytes available at data.
 * \param[out] output Receives one owned reference, including any partial result on failure.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_decode_string(int text, const unsigned char* data, size_t size, cardano_buffer_t** output, char* error, size_t error_size);

/**
 * \brief Encodes a Boolean without exposing native bool layout. Output owns one buffer reference.
 *
 * \param[in] value Zero encodes false; nonzero encodes true.
 * \param[out] output Receives one owned reference, including any partial result on failure.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_encode_bool(int value, cardano_buffer_t** output, char* error, size_t error_size);

/**
 * \brief Reads an untagged Boolean and writes 0 or 1 without exposing native bool layout.
 *
 * \param[in] data Borrowed bytes kept valid until the call returns.
 * \param[in] size Number of bytes available at data.
 * \param[out] value Receives the decoded Boolean as 0 or 1.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_decode_bool(const unsigned char* data, size_t size, int* value, char* error, size_t error_size);

/**
 * \brief Encodes a definite array or map around validated concatenated items. Map count counts pairs. Child bytes remain exact.
 *
 * \param[in] map Zero selects an array; nonzero selects a map.
 * \param[in] count Array element count or map pair count; must fit INT64_MAX.
 * \param[in] data Borrowed bytes kept valid until the call returns.
 * \param[in] size Number of bytes available at data.
 * \param[out] output Receives one owned reference, including any partial result on failure.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_encode_collection(int map, size_t count, const unsigned char* data, size_t size, cardano_buffer_t** output, char* error, size_t error_size);

/**
 * \brief Creates one owned reader that copies the borrowed input. Empty input is a decoding failure.
 *
 * \param[in] data Borrowed bytes kept valid until the call returns.
 * \param[in] size Number of bytes available at data.
 * \param[out] output Receives one owned reference, including any partial result on failure.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_reader_new(const unsigned char* data, size_t size, cardano_cbor_reader_t** output, char* error, size_t error_size);

/**
 * \brief Opens an array or map in a borrowed reader. Both definite and indefinite lengths are accepted.
 *
 * \param[in,out] reader Borrowed reader whose parsing position is advanced or inspected.
 * \param[in] map Zero selects an array; nonzero selects a map.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_collection_start(cardano_cbor_reader_t* reader, int map, char* error, size_t error_size);

/**
 * \brief Peeks whether the borrowed reader is at the matching collection end and writes 0 or 1.
 *
 * \param[in,out] reader Borrowed reader whose parsing position is advanced or inspected.
 * \param[in] map Zero selects an array; nonzero selects a map.
 * \param[out] at_end Receives 0 or 1 indicating whether the matching collection end was reached.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_collection_at_end(cardano_cbor_reader_t* reader, int map, int* at_end, char* error, size_t error_size);

/**
 * \brief Closes the collection and rejects trailing bytes. The borrowed reader remains owned by the caller.
 *
 * \param[in,out] reader Borrowed reader whose parsing position is advanced or inspected.
 * \param[in] map Zero selects an array; nonzero selects a map.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_collection_end(cardano_cbor_reader_t* reader, int map, char* error, size_t error_size);

/**
 * \brief Copies the next encoded child into one owned buffer without normalizing its original representation.
 *
 * \param[in,out] reader Borrowed reader whose parsing position is advanced or inspected.
 * \param[out] output Receives one owned reference, including any partial result on failure.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int; output values are valid on success.
 */
unsigned int cometa_cbor_read_item(cardano_cbor_reader_t* reader, cardano_buffer_t** output, char* error, size_t error_size);

/**
 * \brief Retrieves the unread byte count of a borrowed reader.
 *
 * \param[in] reader Borrowed reader retained until this call returns.
 * \param[out] remaining Receives the number of unread bytes.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A cardano-c status converted to unsigned int.
 */
unsigned int cometa_cbor_reader_remaining(cardano_cbor_reader_t* reader, size_t* remaining, char* error, size_t error_size);

/**
 * \brief Copies one definite-length text chunk from an indefinite text string's interior.
 *
 * \param[in,out] reader Borrowed reader advanced past exactly one definite text string.
 * \param[out] output Receives one owned buffer containing the chunk's encoded bytes.
 * \param[out] error Caller-owned diagnostic buffer; NULL disables diagnostic copying.
 * \param[in] error_size Diagnostic capacity in bytes, including the null terminator.
 *
 * \returns A native status converted to unsigned int. Tags, nested indefinite strings and other
 *          chunk types return CARDANO_ERROR_DECODING. Partial output references remain caller-owned.
 */
unsigned int cometa_cbor_read_text_chunk(cardano_cbor_reader_t* reader, cardano_buffer_t** output, char* error, size_t error_size);

/**
 * \brief Consumes one reader reference. The caller invalidates its released slot even when another owner retains it.
 *
 * \param[in,out] reader Slot containing one reader reference to release; NULL is tolerated.
 */
void cometa_cbor_reader_unref(cardano_cbor_reader_t** reader);

/**
 * \brief Consumes one buffer reference. The caller invalidates its released slot even when another owner retains it.
 *
 * \param[in,out] buffer Slot containing one buffer reference to release; NULL is tolerated.
 */
void cometa_cbor_buffer_unref(cardano_buffer_t** buffer);

/**
 * \brief Borrows buffer storage until its owner is released or mutated. Empty buffers may have no data storage.
 *
 * \param[in] buffer Borrowed buffer retained for the duration of this call.
 *
 * \returns Borrowed storage, which may be NULL for an empty buffer.
 */
const unsigned char* cometa_cbor_buffer_data(const cardano_buffer_t* buffer);

/**
 * \brief Retrieves the byte length of a borrowed buffer, including zero for an empty decoded string.
 *
 * \param[in] buffer Borrowed buffer retained for the duration of this call.
 *
 * \returns The buffer length in bytes.
 */
size_t cometa_cbor_buffer_size(const cardano_buffer_t* buffer);

#ifdef __cplusplus
}
#endif /* __cplusplus */

#endif // BIGLUP_LABS_INCLUDE_COMETA_CBOR_H
