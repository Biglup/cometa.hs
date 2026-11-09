/**
 * \file numeric_conversions_oracle.c
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
#include <math.h>
#include <string.h>

/* STATIC FUNCTIONS **********************************************************/

/* Negative rendering bases are supported by to_string, but the native size
 * helper passes them into mpz_sizeinbase, which asserts. Count using the equal-
 * width positive alphabet instead; call the actual size API only in its safe
 * positive-base domain. No aborting native argument is used by this oracle. */
static int
render_integer(const cardano_bigint_t* value, int32_t base, char* output, size_t capacity, size_t* required)
{
  if (!((base >= -36 && base <= -2) || (base >= -1 && base <= 62)))
  {
    return CARDANO_ERROR_INVALID_ARGUMENT;
  }

  const int32_t sizing_base = (base >= -1 && base <= 1) ? 10 : (base < 0 ? -base : base);

  *required = cardano_bigint_get_string_size(value, sizing_base);
  if ((*required == 0U) || (*required > capacity))
  {
    return CARDANO_ERROR_INSUFFICIENT_BUFFER_SIZE;
  }

  return cardano_bigint_to_string(value, output, *required, base);
}

/* DEFINITIONS ***************************************************************/

/* kind0=BigInt, kind1=metadata, kind2=Plutus data. Getters retain BigInts;
 * every local owner and returned getter reference is released on every exit. */
int
cometa_test_numeric_text(
  int         kind,
  int32_t     parse_base,
  int32_t     render_base,
  const char* text,
  size_t      size,
  char*       output,
  size_t      capacity,
  size_t*     required)
{
  cardano_bigint_t*      integer  = NULL;
  cardano_metadatum_t*   metadata = NULL;
  cardano_plutus_data_t* data     = NULL;
  cardano_error_t        status   = CARDANO_ERROR_INVALID_ARGUMENT;

  if (!((parse_base == 0) || (parse_base >= 2 && parse_base <= 62)))
  {
    return status;
  }

  switch (kind)
  {
    case 0:
      status = cardano_bigint_from_string(text, size, parse_base, &integer);
      break;
    case 1:
      status = cardano_metadatum_new_integer_from_string(text, size, parse_base, &metadata);
      if (status == CARDANO_SUCCESS)
      {
        status = cardano_metadatum_to_integer(metadata, &integer);
      }
      break;
    case 2:
      status = cardano_plutus_data_new_integer_from_string(text, size, parse_base, &data);
      if (status == CARDANO_SUCCESS)
      {
        status = cardano_plutus_data_to_integer(data, &integer);
      }
      break;
    default:
      break;
  }

  if (status == CARDANO_SUCCESS)
  {
    status = render_integer(integer, render_base, output, capacity, required);
  }

  cardano_bigint_unref(&integer);
  cardano_metadatum_unref(&metadata);
  cardano_plutus_data_unref(&data);
  return status;
}

/* Check zero modulus, missing inverse and negative-power invertibility BEFORE
 * calling void native arithmetic. mini-GMP aborts for those invalid domains. */
int
cometa_test_numeric_modular(int power, const char* value_text, const char* exponent_text, const char* modulus_text, char* output, size_t capacity)
{
  cardano_bigint_t* value     = NULL;
  cardano_bigint_t* exponent  = NULL;
  cardano_bigint_t* modulus   = NULL;
  cardano_bigint_t* result    = NULL;
  cardano_bigint_t* magnitude = NULL;
  cardano_bigint_t* divisor   = NULL;
  cardano_bigint_t* one       = NULL;
  cardano_error_t   status    = CARDANO_SUCCESS;
  size_t            required  = 0U;

  status = cardano_bigint_from_string(value_text, strlen(value_text), 10, &value);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  status = cardano_bigint_from_string(exponent_text, strlen(exponent_text), 10, &exponent);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  status = cardano_bigint_from_string(modulus_text, strlen(modulus_text), 10, &modulus);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  status = cardano_bigint_from_int(0, &result);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  status = cardano_bigint_from_int(0, &magnitude);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  status = cardano_bigint_from_int(0, &divisor);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }
  status = cardano_bigint_from_int(1, &one);
  if (status != CARDANO_SUCCESS)
  {
    goto cleanup;
  }

  cardano_bigint_abs(modulus, magnitude);
  if (cardano_bigint_is_zero(modulus) || cardano_bigint_bit_length(exponent) > 256U)
  {
    status = CARDANO_ERROR_INVALID_ARGUMENT;
    goto cleanup;
  }

  if (!power || cardano_bigint_signum(exponent) < 0)
  {
    cardano_bigint_gcd(value, modulus, divisor);
    if (cardano_bigint_compare(magnitude, one) <= 0 || !cardano_bigint_equals(divisor, one))
    {
      status = CARDANO_ERROR_INVALID_ARGUMENT;
      goto cleanup;
    }
  }

  if (power)
  {
    cardano_bigint_mod_pow(value, exponent, modulus, result);
  }
  else
  {
    cardano_bigint_mod_inverse(value, modulus, result);
  }
  status = render_integer(result, 10, output, capacity, &required);

cleanup:
  cardano_bigint_unref(&one);
  cardano_bigint_unref(&divisor);
  cardano_bigint_unref(&magnitude);
  cardano_bigint_unref(&result);
  cardano_bigint_unref(&modulus);
  cardano_bigint_unref(&exponent);
  cardano_bigint_unref(&value);
  return status;
}

int
cometa_test_unit_double(double value, uint64_t* numerator, uint64_t* denominator, double* approximate)
{
  cardano_unit_interval_t* interval = NULL;
  cardano_error_t          status   = CARDANO_SUCCESS;

  if (!isfinite(value) || value < 0.0 || value >= 18446744073709551616.0)
  {
    return CARDANO_ERROR_INVALID_ARGUMENT;
  }

  /* Safety preflight only: reject native uint64 numerator overflow. Expected
   * fractions are still obtained from the actual native constructor/getters. */
  {
    const double   whole_double = floor(value);
    const uint64_t whole        = (uint64_t)whole_double;
    uint64_t       n            = (uint64_t)floor((value - whole_double) * 1000000000000000.0);
    uint64_t       d            = UINT64_C(1000000000000000);
    uint64_t       a            = n;
    uint64_t       b            = d;

    while (b != 0U)
    {
      const uint64_t remainder = a % b;
      a                        = b;
      b                        = remainder;
    }
    n /= a;
    d /= a;
    if (whole > (UINT64_MAX - n) / d)
    {
      return CARDANO_ERROR_INVALID_ARGUMENT;
    }
  }

  status = cardano_unit_interval_from_double(value, &interval);
  if (status == CARDANO_SUCCESS)
  {
    *numerator   = cardano_unit_interval_get_numerator(interval);
    *denominator = cardano_unit_interval_get_denominator(interval);
    *approximate = cardano_unit_interval_to_double(interval);
  }
  cardano_unit_interval_unref(&interval);
  return status;
}

int
cometa_test_unit_to_double(uint64_t numerator, uint64_t denominator, double* approximate)
{
  cardano_unit_interval_t* interval = NULL;
  cardano_error_t          status   = cardano_unit_interval_new(numerator, denominator, &interval);
  if (status == CARDANO_SUCCESS)
  {
    *approximate = cardano_unit_interval_to_double(interval);
  }
  cardano_unit_interval_unref(&interval);
  return status;
}
