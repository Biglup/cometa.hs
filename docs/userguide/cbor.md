# CBOR encoding

CBOR represents integers, bytes, text, arrays, and maps in a compact binary format.
Use a qualified import to distinguish encoding operations from your domain values:

```haskell
import qualified Cometa.Encoding.Cbor as Cbor
```

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
