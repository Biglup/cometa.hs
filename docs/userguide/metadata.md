# Transaction metadata

`Cometa.Metadata` builds validated, immutable metadata. A transaction metadata
label is a `Word64`; its value can be an integer, bytes, Unicode text, a list, or
a map. Integers range from `-2^64` through `2^64-1`. Byte strings contain at most
64 bytes. Text strings contain at most 64 **UTF-8 bytes**, rather than 64
characters. Empty strings, lists and maps are valid.

Validate external leaves once with `mkInteger`, `mkBytes` and `mkText`. Then
assemble lists and maps with total functions. Nested maps preserve pair order
and duplicate keys; they are not Haskell `Map` values. Transaction labels are
unique: `mkMetadata` rejects duplicate labels, `singleton` makes one label, and
`toList` returns ascending labels. Combining transaction metadata with `<>`
gives the left value precedence when both operands contain the same label.

The packaged `cometa-metadata` example creates a label-674 message, encodes it,
reloads it and hashes the saved bytes. It has one error boundary and needs no
network connection or credentials:

```{literalinclude} ../../examples/Metadata.hs
:language: haskell
:start-at: "{-# LANGUAGE OverloadedStrings #-}"
```

Run it with:

```console
cabal run cometa-metadata
```

## Preserve received encodings

`decodeCbor` validates a complete transaction metadata map and returns an
`EncodedMetadata`. `toCbor` retrieves the exact input bytes. `toMetadata`
retrieves its semantic value. The corresponding operations for a single nested
value are `decodeMetadatumCbor`, `toMetadatumCbor` and `toMetadatum`.

Two imported encodings can contain equal semantic values while comparing unequal
as encoded values. For example, indefinite collections and nonminimal integers
can encode the same value differently. `encodeCbor . toMetadata` explicitly
normalizes an imported value to definite collections, minimal integers and
ascending transaction labels. Nested map order and duplicates survive. This is
not a promise to sort arbitrary nested map keys into canonical order.

Hash exact imported bytes when their representation determines identity. A
BLAKE2b digest of the metadata map alone is **not** the transaction's auxiliary
data hash: auxiliary data can include scripts and an era-dependent outer
structure. The example prints a digest of its metadata encoding only.

Decoding rejects trailing input, tags including tagged bignums, unsupported
values such as Boolean/null, invalid UTF-8, strings longer than 64 decoded bytes,
and duplicate transaction labels. Indefinite
string chunks must independently contain valid UTF-8. Definite and indefinite
arrays, maps and strings are otherwise accepted.

## Detailed JSON interchange

`toDetailedJson` and `fromDetailedJson` use the cardano-api **detailed schema**.
Transaction metadata is an object with canonical decimal label keys. A nested
value uses exactly one field:

| Value | JSON shape |
| --- | --- |
| Integer | `{"int": 42}` |
| Bytes | `{"bytes": "00ff"}` |
| Text | `{"string": "hello"}` |
| List | `{"list": [{"int": 42}]}` |
| Map | `{"map": [{"k": {"int": 1}, "v": {"string": "one"}}]}` |

Map pair arrays preserve order and duplicate keys. Byte strings use hexadecimal
without a prefix. JSON integer conversion is exact and rejects fractional or
out-of-range numbers. These functions operate on `Data.Aeson.Value`; parsing or
rendering JSON bytes uses the ordinary Aeson functions. At that boundary JSON
object duplicate-key handling follows Aeson; the metadata pair arrays remain
unambiguous. This schema differs from CIP-116 inspector JSON and does not infer
bytes or integers from arbitrary text strings.
