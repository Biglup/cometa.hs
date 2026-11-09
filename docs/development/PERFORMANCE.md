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

## Local measurements, 2026-11-09

Linux x86-64, Intel Core i7-1265U, GHC 9.6.7 with Cabal's default `-O1`.
The static cardano-c dependency is `c5edc7c8f16b3980b6e97ef7fda80fef94adf980`,
built as RelWithDebInfo (`-O2 -g -DNDEBUG`). No local build ran during the final
measurements. Each of five process runs performed 1,000 iterations per operation.
The table reports median and range of the five per-run means.

| Operation | Median µs/op | Range µs/op |
| --- | ---: | ---: |
| Native payment build and serialization | 119.90 | 118.80–123.52 |
| Native transaction signing and serialization | 78.14 | 77.53–79.84 |
| Native inspection and JSON encoding | 14.51 | 14.45–14.68 |
| Haskell CBOR decode and exact encode | 5.36 | 5.26–5.48 |

Twenty separate one-iteration invocations took a median 12.41 ms per process
(range 11.19–13.51 ms), measured around process creation and exit. This includes
fixture setup, first build, key acquisition, warm-ups, all four operations and
runtime teardown. It is not an isolated library-loading measurement or a cold
filesystem-cache test. The unstripped benchmark executable was 35,475,856 bytes;
that includes Haskell dependencies and debug/symbol data, not just Cometa.

RTS statistics report Haskell allocations across the complete process, including
setup. They exclude native allocation traffic and do not establish absence of
leaks. Use the separate Valgrind checks for native lifetime validation.

These measurements do not cover large transactions, script evaluation, provider
HTTP latency, concurrency, other compilers/platforms or low-power hardware. They
establish a baseline for future comparisons; no optimization or ownership-policy
change is justified by these results alone. CI runs one iteration to verify that
the harness builds and executes, without enforcing timing thresholds.
