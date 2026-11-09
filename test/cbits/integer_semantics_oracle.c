/**
 * \file integer_semantics_oracle.c
 *
 * \author angel.castillo
 * \date   Nov 09, 2026
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
#include <stdint.h>
#include <string.h>

/* DEFINITIONS ***************************************************************/

/* Test-only differential oracle for the pinned common/bigint.c API. Original
 * test code, not copied mini-GMP implementation code. The arithmetic source
 * reviewed is lib/external/gmp/mini-gmp.c (LGPLv3+/GPLv2+).
 *
 * Every operation allocates distinct input/result owners and releases all four
 * on success, parse failure, rejected precondition, or insufficient output.
 * Guard zero divisors BEFORE native void arithmetic: mini-GMP aborts on zero.
 * Bounds are oracle resource limits, not claimed native API restrictions. */
int
cometa_test_integer_semantics(
  uint8_t     operation,
  const char* left,
  const char* right,
  uint32_t    argument,
  char*       output,
  size_t      capacity)
{
  cardano_bigint_t* first     = NULL;
  cardano_bigint_t* second    = NULL;
  cardano_bigint_t* result    = NULL;
  cardano_bigint_t* remainder = NULL;
  cardano_error_t   status    = CARDANO_SUCCESS;

  if ((left == NULL) || (right == NULL) || (output == NULL) || (capacity == 0U))
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }

  if ((strlen(left) > 256U) || (strlen(right) > 256U) || (argument > 4096U))
  {
    return CARDANO_ERROR_INVALID_ARGUMENT;
  }

  status = cardano_bigint_from_string(left, strlen(left), 10, &first);

  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  status = cardano_bigint_from_string(right, strlen(right), 10, &second);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  status = cardano_bigint_from_int(0, &result);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  status = cardano_bigint_from_int(0, &remainder);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  if ((operation >= 3U) && (operation <= 6U) && cardano_bigint_is_zero(second))
  {
    status = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }

  switch (operation)
  {
    case 0:
      cardano_bigint_add(first, second, result);
      break;
    case 1:
      cardano_bigint_subtract(first, second, result);
      break;
    case 2:
      cardano_bigint_multiply(first, second, result);
      break;
    case 3:
      cardano_bigint_divide(first, second, result);
      break;
    case 4:
      cardano_bigint_reminder(first, second, result);
      break;
    case 5:
      cardano_bigint_mod(first, second, result);
      break;
    case 6:
      cardano_bigint_divide_and_reminder(first, second, result, remainder);
      break;
    case 7:
      cardano_bigint_and(first, second, result);
      break;
    case 8:
      cardano_bigint_or(first, second, result);
      break;
    case 9:
      cardano_bigint_xor(first, second, result);
      break;
    case 10:
      cardano_bigint_not(first, result);
      break;
    case 11:
      cardano_bigint_shift_left(first, argument, result);
      break;
    case 12:
      cardano_bigint_shift_right(first, argument, result);
      break;
    case 13:
      cardano_bigint_unref(&result);
      status = cardano_bigint_from_int(cardano_bigint_test_bit(first, argument) ? 1 : 0, &result);
      break;
    case 14:
      cardano_bigint_set_bit(first, argument);
      cardano_bigint_assign(first, result);
      break;
    case 15:
      cardano_bigint_clear_bit(first, argument);
      cardano_bigint_assign(first, result);
      break;
    case 16:
      cardano_bigint_flip_bit(first, argument);
      cardano_bigint_assign(first, result);
      break;
    case 17:
      cardano_bigint_unref(&result);
      status = cardano_bigint_from_unsigned_int(cardano_bigint_bit_count(first), &result);
      break;
    case 18:
      cardano_bigint_unref(&result);
      status = cardano_bigint_from_unsigned_int(cardano_bigint_bit_length(first), &result);
      break;
    case 19:
      /* Keep power output bounded independently of the shift/index limit. */
      if (argument > 16U)
      {
        status = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
      }
      cardano_bigint_pow(first, argument, result);
      break;
    case 20:
      cardano_bigint_gcd(first, second, result);
      break;
    case 21:
      cardano_bigint_abs(first, result);
      break;
    case 22:
      cardano_bigint_negate(first, result);
      break;
    case 23:
      cardano_bigint_unref(&result);
      status = cardano_bigint_from_int(cardano_bigint_signum(first), &result);
      break;
    case 24:
      cardano_bigint_min(first, second, result);
      break;
    case 25:
      cardano_bigint_max(first, second, result);
      break;
    case 26:
      cardano_bigint_increment(first);
      cardano_bigint_assign(first, result);
      break;
    case 27:
      cardano_bigint_decrement(first);
      cardano_bigint_assign(first, result);
      break;
    case 28:
      cardano_bigint_unref(&result);
      status = cardano_bigint_from_unsigned_int(cardano_bigint_to_unsigned_int(first), &result);
      break;
    case 29:
      cardano_bigint_unref(&result);
      status = cardano_bigint_from_unsigned_int(cardano_bigint_get_bytes_size(first), &result);
      break;
    case 30:
      /* A bounded witness for uint64 -> unsigned long narrowing on LLP64.
       * 0^(2^32) is always cheap; never accept an arbitrary giant power. */
      if (!cardano_bigint_is_zero(first))
      {
        status = CARDANO_ERROR_INVALID_ARGUMENT;
        break;
      }
      cardano_bigint_pow(first, UINT64_C(1) << 32, result);
      break;
    default:
      status = CARDANO_ERROR_INVALID_ARGUMENT;
      break;
  }

  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  {
    const size_t first_size = cardano_bigint_get_string_size(result, 10);
    if ((first_size == 0U) || (first_size > capacity))
    {
      status = CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE;
      goto cleanup;
    }
    status = cardano_bigint_to_string(result, output, first_size, 10);
    if ((status == CARDANO_SUCCESS) && (operation == 6U))
    {
      const size_t second_size = cardano_bigint_get_string_size(remainder, 10);
      if ((second_size == 0U) || (second_size > capacity - first_size))
      {
        status = CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE;
        goto cleanup;
      }
      output[first_size - 1U] = ' ';
      status                  = cardano_bigint_to_string(remainder, output + first_size, second_size, 10);
    }
  }
cleanup:
  cardano_bigint_unref(&remainder);
  cardano_bigint_unref(&result);
  cardano_bigint_unref(&second);
  cardano_bigint_unref(&first);
  return (int)status;
}

/* Magnitude byte import/export, independently checked against Haskell folds.
 * Zero's native export error is intentionally returned, never patched here. */
int
cometa_test_integer_bytes(
  const unsigned char* input,
  size_t               input_size,
  uint8_t              little_endian,
  unsigned char*       output,
  size_t               output_capacity,
  char*                decimal,
  size_t               decimal_capacity)
{
  if ((input == NULL) || (output == NULL) || (decimal == NULL) || (decimal_capacity == 0U))
  {
    return CARDANO_ERROR_POINTER_IS_NULL;
  }
  decimal[0]               = '\0';
  cardano_bigint_t* value  = NULL;
  cardano_error_t   status = cardano_bigint_from_bytes(input, input_size, little_endian ? CARDANO_BYTE_ORDER_LITTLE_ENDIAN : CARDANO_BYTE_ORDER_BIG_ENDIAN, &value);
  if (status == CARDANO_SUCCESS)
  {
    const size_t required = cardano_bigint_get_string_size(value, 10);
    if ((required == 0U) || (required > decimal_capacity))
    {
      status = CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE;
    }
    else
    {
      status = cardano_bigint_to_string(value, decimal, required, 10);
    }
  }

  if (status == CARDANO_SUCCESS)
  {
    const size_t required = cardano_bigint_get_bytes_size(value);
    if (required > output_capacity)
    {
      status = CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE;
    }
    else
    {
      status = cardano_bigint_to_bytes(value, little_endian ? CARDANO_BYTE_ORDER_LITTLE_ENDIAN : CARDANO_BYTE_ORDER_BIG_ENDIAN, output, required);
    }
  }
  cardano_bigint_unref(&value);
  return (int)status;
}
