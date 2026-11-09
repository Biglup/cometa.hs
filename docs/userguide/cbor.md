# CBOR encoding

CBOR represents integers, bytes, text, arrays, and maps in a compact binary format.
Use a qualified import to distinguish encoding operations from your domain values:

```haskell
import qualified Cometa.Encoding.Cbor as Cbor
```

## Decode raw hexadecimal

Use `Cometa.Encoding.Hex` when hexadecimal text contains raw bytes rather than a
complete CBOR item. Decode the text, then apply the intended domain validator:

```haskell
import qualified Cometa.Encoding.Hex as Hex
import qualified Cometa.Script.Plutus as Plutus

readScript text = Hex.decode text >>= Plutus.fromBytes Plutus.V3
```

`Hex.decode` accepts either case and empty input. It rejects odd lengths,
whitespace, prefixes and non-hexadecimal characters with `InvalidHex`.
`Hex.encode` returns lowercase text. Both functions are pure; a successful hex
decode does not establish that the bytes form a valid script or other domain value.

## Read an encoded value

`fromBytes` reads one complete item from a `ByteString`. `fromHex` accepts the
same bytes as hexadecimal text. Both return `IO (Either Error Cbor)` and reject
trailing data. Hexadecimal input accepts either case, without whitespace or a
`0x` prefix.

`toBytes` returns the original bytes; `toHex` renders them as lowercase
hexadecimal. Importing and exporting a value does not normalize its encoding.
Equality compares encoded bytes, so two encodings of the same integer can compare
unequal.

Parsing CBOR does not establish that the value is a valid Cardano transaction,
address, script, or other domain object. Use the corresponding domain decoder for
that validation. Structural parsing also does not check tag semantics or the
UTF-8 contents of arbitrary nested text. `decodeText` validates text when you
inspect it.

## Encode and decode values

The scalar codecs work with Haskell `Integer`, `ByteString`, `Text`, and `Bool`
values. Their operations return `IO (Either Error ...)`; a type mismatch is an
error, not a default value.

```haskell
import qualified Cometa.Encoding.Cbor as Cbor

main :: IO ()
main = do
  encoded <- Cbor.encodeInteger 42

  case encoded of
    Left failure -> print failure
    Right value -> do
      print (Cbor.toHex value)
      decoded <- Cbor.decodeInteger value
      print decoded
```

Integer codecs cover primitive CBOR integers from `-18446744073709551616` through
`18446744073709551615`, inclusive. Larger integers require tagged bignum encodings
and are not accepted by these codecs. Text decoding checks UTF-8, including each chunk of an indefinite-length string.

The repository includes a complete example:

```sh
cabal run cometa-cbor
```

## Preserve arrays and maps

`encodeArray` and `decodeArray` use `[Cbor]`, preserving element order.
`encodeMap` and `decodeMap` use `[(Cbor, Cbor)]`, preserving entry order and
duplicate keys. A list of pairs is intentional: converting to `Data.Map` would
merge duplicate keys and change their order.

A decoded child retains its own bytes. Building a new array or map writes a new
container around those children. To preserve an entire original encoding,
export the original `Cbor` value instead of rebuilding it.

## Standalone ledger collections

`Cometa.Encoding.Collections` encodes and decodes three collection shapes:

| Functions | Haskell values |
| --- | --- |
| `encodeAssetNamesCbor`, `decodeAssetNamesCbor` | `[(AssetName, Integer)]` for one policy's quantities |
| `encodeWithdrawalsCbor`, `decodeWithdrawalsCbor` | `[(RewardAddress, Word64)]` |
| `encodeHashesCbor`, `decodeHashesCbor` | `[Blake2bHash]` |

Lists preserve duplicate entries and explicit zero quantities. Codecs use native
collection ordering; they do not apply the normalization rules of `Value` or
`Data.Map`. Asset quantities are checked against signed 64-bit bounds when
encoding; withdrawal amounts cover the full unsigned 64-bit range. Empty maps
and hash collections are representable even where a containing transaction field
would prohibit them.

Hash arrays use tag 258 by default. `encodeHashesCborWith UntaggedSet` produces an
untagged array; decoding accepts either form. This is a representation choice:
native hash-set re-encoding always emits the tagged form. Persist the original
bytes separately when exact imported encoding matters.

## Floating-point and simple values

`decodeDouble` accepts half-, single- and double-precision encodings and returns a
Haskell `Double`, including signed zero, infinities and NaN. It does not coerce
integer items. Inspecting a value leaves its original encoding unchanged.

`decodeSimple` returns a `Word8`: false is 20, true is 21, null is 22 and undefined
is 23. It also accepts other byte-valued simple items accepted by the native
reader; application-specific meanings remain the caller's responsibility.
`encodeUndefined` produces `f7`. Undefined is distinct from null and an absent
map entry. These operations use the same `IO (Either Error ...)` boundary as the
other scalar codecs.
