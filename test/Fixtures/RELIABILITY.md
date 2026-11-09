# Independent reliability properties

These tests call the public Haskell API backed by cardano-c. Expected arithmetic,
hashes and signatures are calculated independently. They test library contracts;
they do not run the ledger state machine or prove that a transaction is admissible
on a network. No upstream implementation, generator or test vector was copied.

## Selection

`SelectionReliability.hs` extends the laws reviewed in
[cardano-coin-selection BalanceSpec](https://github.com/cardano-foundation/cardano-coin-selection/blob/57efda2eda720b9e793a6f907319cc84aa02058c/test/spec/Cardano/CoinSelection/BalanceSpec.hs):
`prop_performSelection`, the user/non-user asset change sum properties, and
`genSelectionParams`. The source revision, Apache-2.0 license and notices are
recorded in [COIN_SELECTION.md](COIN_SELECTION.md).

The new generators cover sparse asset incidence, signed funding requirements,
mandatory inputs, output shape hints, both change address lengths, and retained
datum/reference-script snapshots. Every policy must preserve the eligible input
partition and satisfy per-asset conservation using independent Integer maps.
A minted asset absent from every input must appear in change.

Minimum Ada uses the least fixed point of
`coin = costPerByte * (160 + encodedOutputBytes)`. Only the public Haskell CBOR
encoder supplies byte lengths; no native fee helper supplies the expectation.
Exactly sufficient token change succeeds; one lovelace less fails with the
insufficient-funds status, after which the same selector must still succeed.
The generated domain bounds quantities and supplies enough Ada for the success
cases. It deliberately does not prescribe random selection order.

## Transaction identity and signatures

`IdentityReliability.hs` checks six differently encoded but semantically equal
bodies against literal BLAKE2b-256 hashes and Ed25519 signatures from two keys.
Envelope framing, script validity and outer witness order must not change the
signed message. Nested witness changes must affect the enclosing body commitment
while preserving the nested body identity. Cross-message signatures must fail.

The reviewed signing contract is
[cardano-api Sign.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Tx/Internal/Sign.hs)
(`makeShelleySignature`, `makeShelleyKeyWitness'`, `hashTxBody`). The stale nested
body signature case comes from
[ledger SubUtxowSpec](https://github.com/IntersectMBO/cardano-ledger/blob/7827506b7518284d7f9dbbe3502a20431e513fe9/eras/dijkstra/impl/testlib/Test/Cardano/Ledger/Dijkstra/Imp/SubUtxowSpec.hs)
(`SubInvalidWitnessesUTXOW`). Both sources are Apache-2.0. The latter file was
retrieved at the stated revision and has SHA-256
`a6eca1fb7ba28d2dd82fe8f13b3870f816f3cb50a37294404dc6941de71b494f`.

The original fixtures were generated with Python `hashlib` and cryptography
48.0.0 (OpenSSL 4.0.0), without Cometa or cardano-c. For each `bodyHex` literal,
the independent calculation is:

```python
import hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

body = bytes.fromhex(body_hex)
digest = hashlib.blake2b(body, digest_size=32).digest()
key = Ed25519PrivateKey.from_private_bytes(bytes([7]) * 32)
signature = key.sign(digest)
```

Repeat with seed byte 8 for the second signature. These are public synthetic
fixtures, not wallet material. The nested body is the same input/output map with
the fee field omitted. A nested frame is `[body, witnesses, null]`; its enclosing
body has empty tagged inputs, empty outputs, fee 10, and field 23 containing its
single tagged subtransaction. The four nested witness sets contain zero, one,
two, or the same two signatures in reverse order. Hash each complete enclosing
body with the same independent formula. Ordinary tests use only the literal
results and have no Python/OpenSSL dependency.

These structural fixtures include empty outputs and do not claim ledger validity.
