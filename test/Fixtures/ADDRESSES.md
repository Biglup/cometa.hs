# Shelley address fixtures

`Fixtures/Address.hs` imports the 16 base/enterprise/reward mainnet/testnet
Bech32 vectors from cardano-c commit
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`,
`lib/tests/address/cip19_test_vectors.h`, under Apache-2.0 (copyright Biglup
Labs, 2024; native header retains attribution to CIP-19). Hash bytes in `Address.hs`
come from the same fixture. Current verification uses a fresh native static
build of the merged revision with interprocedural optimization disabled, matching
the repository CI recipe. The earlier reviewed source revision
`7a65f2c7309bbba9e86f6aa73214b003fab88aee` has identical relevant source content.
No upstream test/generator implementation was copied. Equality with native
constructors and Bech32 operations is binding conformance, not an independent
cryptographic or ledger oracle.

The test-only C oracle reconstructs native credentials and each supported
address form from separate Haskell header/hash fields, checks native header,
network, exact bytes and pure Haskell Bech32 text, and releases all references.
Every form is tested on all 16 network tags. A separate native Bech32 encoder deliberately produces
valid-checksum mismatched HRPs and trailing payloads, proving strict Haskell
rejection independently of checksum validation. New shrinking generators are
local Hedgehog code; no imported generator license applies.

The production text codec uses bech32 >=1.1.10 && <1.2 (locally tested with
1.1.11). Its four private built-in prefixes use the public HRP validator; a
source-controlled fixed-literal invariant assertion is checked by direct prefix
validation and all 16 native text vectors. No external input reaches that
assertion, and there is no native call or unsafePerformIO in the codecs.

The suite checks exact input bounds, all supported discriminants, unsupported
pointer/Byron/reserved discriminants, lowercase and uppercase input, mixed-case
and malformed text, public-key hashing, copied-value GC survival, repeated
success/failure, strict nonzero/excessive bit padding, and shared pure codec
evaluation through GC. There is no persistent native address handle or callback
registry in production.
Deterministic native allocation-failure injection is not implemented.
