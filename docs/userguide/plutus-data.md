# Build and preserve a datum

Use `Cometa.PlutusData` to assemble datum or redeemer values and script parameters.
`Integer` leaves use arbitrary precision. `Bytes` accepts arbitrary bytes, including
empty bytes. Constructor alternatives range from zero through `2^64 - 1`.
Lists retain their order, and maps retain both order and duplicate keys.

```haskell
import qualified Cometa.PlutusData as Data

newDatum :: Data.PlutusData
newDatum = Data.Constr 0 [Data.Integer 42, Data.List []]
```

`encodeCbor newDatum` serializes this new semantic value. Lists and maps have
definite lengths. Large byte strings and bignum payloads are split into chunks
of at most 64 bytes, as required for Plutus Data. Assembly and serialization are
pure.

## Reload a datum and compute its hash

A datum hash depends on its exact CBOR bytes. Two encodings can describe equal
semantic values while producing different hashes. Decode stored or externally
supplied CBOR with `decodeCbor` to obtain an abstract `EncodedPlutusData` value.
Then use `hash` to compute its 32-byte BLAKE2b digest:

```haskell
import qualified Cometa.Crypto.Blake2b as Blake2b
import Cometa.Error (Error)
import qualified Cometa.PlutusData as Data
import Data.ByteString (ByteString)

hashStoredDatum :: ByteString -> IO (Either Error Blake2b.Blake2bHash)
hashStoredDatum stored = case Data.decodeCbor stored of
  Left failure -> pure (Left failure)
  Right datum -> Data.hash datum
```

`decodeCbor` accepts definite and indefinite collections and byte strings, plus
nonminimal integer encodings. It rejects trailing bytes, unsupported CBOR types,
invalid constructor forms and definite byte chunks longer than 64 bytes.
Invalid input returns `InvalidPlutusDataCbor`; native hashing failures return the
usual structured native error.

`toData` inspects the semantic tree without changing the stored encoding.
`toCbor` returns the original bytes exactly. Encoded equality compares those
bytes; compare `toData` results when semantic equality is intended.

To give an edited or freshly assembled tree a new encoding identity, call
`fromData`. Its hash is the hash of the newly generated encoding. Converting
`toData` back through `fromData` can change an external datum's hash even when
its semantic value remains equal.

The `cometa-plutus-data` example builds a nested datum, serializes and reloads it,
and computes its digest without live credentials or network access:

```console
cabal run cometa-plutus-data
```
