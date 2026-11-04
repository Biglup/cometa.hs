# Software-handler fixture provenance

All inputs are public deterministic test material, never application keys or
funded wallet material. No tests use live credentials or a network.

`SoftwareKeyHandler.hs` transcribes numerical vectors from cardano-c revision
`7811fe94dad90f30478ed4b61d96677f188abaa8`,
`lib/tests/key_handlers/software_secure_key_handler.cpp`:
`SERIALIZED_BIP32_KEY_HANDLER`, `EXTENDED_ACCOUNT_0_PUB_KEY`,
`ED25519_NOR_PRIVATE_KEY_HEX`, `ED25519_NOR_PUBLIC_KEY_HEX`,
`ED25519_PRIVATE_KEY_HEX`, and `ED25519_PUBLIC_KEY_HEX`.
Their password is ASCII `password`, and the account path is 1852'/1815'/0'.
The source is Copyright 2024 Biglup Labs, Apache-2.0. This repository retains the
license in `LICENSE`; no native test code was copied.

The fixed serialized input is tested for byte-preserving serialization and its
account public key through public Haskell values. Fresh encryption intentionally
uses random salt/nonce, so only repeated serialization of one handler is equal.
The normal and extended Ed25519 vectors exercise both key modes through scoped
signing keys, not opaque storage forwarding. Additional generated entropy sizes
compare account keys against the existing public BIP32 derivation API; that is
binding conformance, not an independent cryptographic oracle. Maximum raw account
components establish no truncation or ordering error in the C struct adapter.
The concurrency, exception, framing and cancellation scenarios are newly written
Haskell tests. External-consumer compile-fail checks in
`tools/check-key-handler-roles.py` verify capability separation and the nominal
role against `Data.Coerce.coerce`.
