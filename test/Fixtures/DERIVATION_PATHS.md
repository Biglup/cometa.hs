# Derivation-path oracle provenance

Native revision: `7811fe94dad90f30478ed4b61d96677f188abaa8` (cardano-c,
Apache-2.0, Copyright Biglup Labs). Native headers audited:
`lib/include/cardano/key_handlers/{derivation_path,account_derivation_path,cip_1852_constants}.h`.

The nine constants are read directly from pinned headers by
`test/cbits/derivation_path_oracle.c`. Full-path oracle construction adapts the
encoding in `lib/src/key_handlers/software_secure_key_handler.c`,
`bip32_sign_hash`: first three fields cast to uint32 and hardened; final two cast
to uint32. It compares real derived public keys but repeats the native encoding
formula, so it is not an independent cryptographic oracle. Root fixture provenance
is recorded in `BIP32.md`.

The account oracle actually calls the software secure handler with a native
account-path struct and compares all 64 public bytes against public Haskell BIP32
derivation. Standard, multisignature, custom distinct components, and maximum
components are exercised. Its deterministic entropy and standard account xpub
come from `lib/tests/key_handlers/software_secure_key_handler.cpp`,
`ENTROPY_BYTES` and `canCreateABip32SecureKeyHandler`. Test-only encryption password
is `x`; root derivation uses the handler's empty derivation passphrase. This uses
no live wallet or secrets. The handler oracle creates randomized encrypted storage,
but its account public output is deterministic.

Bounds and shrinking Hedgehog properties are original Cometa tests. The Haskell
API rejects every component outside 0..2^31-1; it does not copy native silent
uint64 truncation, high-bit aliasing of hardened prefixes, or hardened role/index
inputs. Custom purpose, coin and role numbers within that range remain supported.
