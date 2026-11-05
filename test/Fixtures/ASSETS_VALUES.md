# Asset and value fixtures

`test/Value.hs` selects identifier bytes from cardano-c revision
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:

- `lib/tests/assets/asset_name.cpp`: `skywalker`, hexadecimal
  `736b7977616c6b6572`.
- `lib/tests/assets/multi_asset.cpp` and
  `lib/tests/transaction_body/value.cpp`: 28-byte all-zero/all-0x11 policies,
  names `30313232`, `33343536`, `40414242`, and the 1,000,000-lovelace coin.

These upstream fixtures are Apache-2.0, copyright Biglup Labs 2024. No upstream
implementation, test, property or generator code was copied. Binary/UTF-8,
zero/negative, exact int64 endpoints and arbitrary-precision cases are local
Cometa tests. The association-list quantity model and shrinking Hedgehog
properties are independently authored here.

The test-only C oracle constructs native names, asset IDs and values from
public Haskell components, compares exact identifier bytes and native Ada flags,
and checks coin/token quantities after native addition/subtraction. It also
checks inputs after arithmetic, detecting observable mutation. It owns and
releases all references in each call; no mutable object escapes. Native agreement
is conformance evidence, not an independent ledger oracle.

Haskell checks every input, sum and difference in Integer against signed int64
bounds before conversion. The native code has unchecked signed arithmetic;
int64 endpoint fixtures use a zero right operand. Native coin fields are signed
int64 even though native output CBOR uses unsigned integers. No decoder, encoder,
production marshaling boundary or native allocation-failure injection is added.
Integer values outside native bounds remain lawful pure bundles, and are tested
without entering C. Negative quantities remain signed; no output or mint validity
is inferred. Native collection duplicate/zero representation and CBOR ordering
are deliberately separate from normalized semantic bundle equality and ordering.
