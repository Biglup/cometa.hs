# BIP32 test fixture provenance

All secrets are deterministic test material, never application keys or funded
wallet material. Tests use no credentials, network, Python packages or random
wallet secrets.

## Imported native vectors

Pinned cardano-c revision: `8dc0c55f4132fcaa2e7961b6cfbfea96a6d93b5d`, matching
`native/cardano-c.ref`. Values in `Fixtures.Bip32` were transcribed from:

- `lib/tests/crypto/bip32_private_key.cpp`: constant `BIP32_PRIVATE_KEY_HEX`;
  `deriveCorrectHardenedKey` for `[1852',1815',0']`;
  `deriveCorrectUnHardenedKey` for `[1852,1815,0]` (this scenario uses a different
  input key); `canComputeTheCorrectPublicKey`; and
  `computesTheRightKeyFromTheEntropyAndPassword`.
- `lib/tests/crypto/bip32_public_key.cpp`: constant `BIP32_PUBLIC_KEY_HEX` and
  `deriveCorrectUnhardenedKey` for `[1852,1815,0]`.

Both native files are Copyright 2024 Biglup Labs, licensed under Apache-2.0.
This repository retains Apache-2.0 in `LICENSE`; this provenance preserves source
attribution. Only numerical vectors were transcribed. These are native Cardano
Ed25519-BIP32 vectors, not Bitcoin/secp256k1 BIP32 or RFC 8032 derivation vectors.
The Haskell Hedgehog generators and properties are new, not copied test code.

## Independent checks

Python 3 standard-library `hashlib.pbkdf2_hmac` independently regenerated the
imported password/entropy root and two additional fixed roots. Recipe:

```python
import hashlib

def root(password, entropy):
    key = bytearray(hashlib.pbkdf2_hmac("sha512", password, entropy, 4096, 96))
    key[0] &= 248
    key[31] = (key[31] & 31) | 64
    return bytes(key).hex()
```

Inputs: imported entropy `caec96d09fc2020ab230199e0188cd6a554e2da2cba32de9ff6c0908c7f04d65`
with ASCII password `some_password_@#$%^&`; sixteen zero bytes with empty password;
and `bytes(range(32))` with password `b"a\x00b"`. The last case proves embedded
NUL preservation. Literal expected outputs are stored in `Fixtures.Bip32`.
`publicHashHex` was computed with
`hashlib.blake2b(bytes.fromhex(publicHex), digest_size=28).hexdigest()`.

These independent checks cover root KDF and full-xpub hashing. Derived child
known answers come from the pinned native corpus; Haskell/native agreement is
not an independent proof of the derivation algorithm.

## Binding contract adaptations and lifecycle

Native root import accepts arbitrary nonempty entropy. The Haskell BIP39 entropy
constructor deliberately accepts only standard BIP39 sizes (16,20,24,28,32 bytes).
Native derive rejects empty paths; Haskell uses the identity law instead: immutable
public reuse or an independent private clone. `harden` preserves native idempotent
high-bit OR semantics. Public derivation rejects high-bit indices before native
work. Length-only key import preserves native validation policy.

Tests cover fixed vectors, invalid lengths/hex/curve points/scalars, boundary
indices, chain codes and Ed25519 projection, public round trips, soft derivation
commutation, path composition, clone/derived/signing independence, early close,
escaped handles, callback errors/exceptions/cancellation, retained native ownership,
concurrent derive/close, input exceptions, public snapshots and GC.

At the pinned revision the final BIP32 private deallocator calls `sodium_memzero`
on its secret buffer before free. The allocation uses ordinary heap storage;
root PBKDF2 result and derivation intermediate stack buffers are not all wiped.
The binding does not claim comprehensive native or Haskell secret erasure.
Deterministic native allocator-failure injection remains unverified here.
