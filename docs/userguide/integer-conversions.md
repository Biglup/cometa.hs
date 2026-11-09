# Integer text, bytes and modular arithmetic

`Cometa.Encoding.Integer` keeps ordinary Haskell `Integer` values and provides
validated radix conversions. Validate a radix once, then use it for parsing and
rendering or pass it to the metadata and Plutus-data integer constructors:

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Cometa.Encoding.Integer as Integer
import Cometa.Error (Error)
import qualified Cometa.Metadata as Metadata
import qualified Cometa.PlutusData as Plutus

example :: Either Error (Metadata.Metadatum, Plutus.EncodedPlutusData)
example = do
  radix <- Integer.mkRadix 16
  metadata <- Metadata.integerFromText radix "-ff"
  argument <- Plutus.integerFromText radix "123456789abcdef0123456789abcdef"
  pure (metadata, argument)
```

Radices 2 through 36 accept either letter case and render lowercase. Radices 37
through 62 use the case-sensitive alphabet `0..9,A..Z,a..z`.
`Integer.toUpperText` provides the native uppercase rendering convention for
bases 2 through 36; it rejects larger radices. `Integer.fromTextAuto` recognizes
`0x`, `0b`, and leading-zero octal forms, with decimal as the default.

Parsing follows the native numeric text rules: an optional minus sign, ASCII
whitespace, and no plus sign. Explicit radix parsing accepts digits without a
prefix. Parsing stops at the first NUL character. Automatic prefix detection
happens after the sign and before removing internal whitespace, so `-0x 1f`
is valid but `- 0x1f` is not. Invalid text returns `InvalidIntegerText`.
Metadata integers must additionally fit `-2^64 .. 2^64-1`; Plutus integers have
arbitrary precision. Automatic-base domain construction is available by composing
`fromTextAuto` with `Metadata.mkInteger` or `Plutus.fromData . Plutus.Integer`.

`Integer.toBytes BigEndian` and `Integer.toBytes LittleEndian` encode minimal
unsigned magnitude bytes. The sign is discarded, and zero is one zero byte.
`Integer.fromBytes` accepts leading zero bytes and treats an empty byte sequence
as zero. These operations use the selected order independently of the host CPU;
they do not encode signed two's-complement byte strings.

`Integer.modularInverse value modulus` returns a residue in
`[0, abs modulus)` when the inverse exists. It returns `InvalidModulus` for
moduli zero or one in magnitude and `NoModularInverse` for noncoprime values.
`Integer.modularPower value power modulus` uses repeated squaring and accepts
negative exponents when the inverse exists. Zero modulus is rejected. The native
zero-exponent convention is retained: the result is one even for modulus `1`
or `-1`; nonzero nonnegative powers modulo these values are zero. These are
variable-time operations with no constant-time guarantee.

## Floating-point proportions

Prefer `UnitInterval.mkUnitInterval` for an exact known fraction.
`UnitInterval.fromDouble` accepts only finite numbers from zero through one and
uses the native decimal-floor conversion: reduce
`floor(value * 10^15) / 10^15`. It may round down; for example, one third becomes
`333333333333333 / 1000000000000000`, while values below `10^-15` can become zero.
NaN, infinities and out-of-range values return `InvalidUnitIntervalDouble`.

`UnitInterval.toDouble` converts the numerator and denominator separately before
dividing, as the native function does. This approximation can differ from
rounding the exact rational quotient once. It does not change the stored exact
numerator and denominator.

For a general nonnegative fraction, `Cometa.Protocol.Rational.fromDouble` also
accepts values above one. It floors the fractional part to 15 decimal places,
reduces it, then adds the whole part; `1.5` becomes `3/2`. The result must fit
unsigned 64-bit numerator and denominator fields. Nonfinite, negative and
oversized whole parts return `InvalidProtocolDouble`; a fractional result whose
numerator would overflow returns `InvalidProtocolRational`. This avoids the
native function's unchecked casts and unsigned overflow on invalid inputs.
`Protocol.Rational.toDouble` uses the same separate-cast approximation as the
unit-interval conversion.
