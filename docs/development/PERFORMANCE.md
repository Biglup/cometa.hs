# Performance baseline

The `cometa-performance` Cabal benchmark measures a small offline payment through
public APIs. It is a repeatable baseline, not a statistical performance guarantee.

## Reproduce

Configure the pinned native library as described in the installation guide, then:

```sh
cabal build bench:cometa-performance
cabal bench cometa-performance --benchmark-options="1000 +RTS -s -RTS"
```

The optional positive argument is the iteration count (default 100). Each operation
has one untimed warm-up and a collection before timing. Fixture preparation and
key acquisition are outside the timed operations. A strict checksum consumes every
output byte. The decoder reads its fixed input through IO each iteration to avoid
timing an already evaluated shared result.

The fixture has one ten-ADA funding input, a two-ADA payment and change. It uses
synthetic protocol parameters and an unfunded public signing seed. Signing includes
serialization of the signed transaction. Inspection includes native inspection,
Haskell JSON decoding and JSON encoding. CBOR measures Haskell decoding and exact
re-emission, preserving original bytes; it is not native canonicalization.
