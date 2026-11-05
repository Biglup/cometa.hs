# Script vectors

Native source revision: `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`.

The four `apply_params` expected encodings and identity script come from
`lib/tests/vectors/bindings/v1/primitives.json` (`apply-params-empty`,
`apply-params-integer-zero`, `apply-params-integer-above-uint64`,
`apply-params-two-parameters`). Guard encodings and nested combinations come from
`lib/tests/scripts/native_scripts/script_require_guard.cpp`, constants
`KEY_HASH_CREDENTIAL_CBOR`, `SCRIPT_HASH_CREDENTIAL_CBOR`, `NESTED_ALL_CBOR`,
`NESTED_ANY_CBOR`, `NESTED_N_OF_K_CBOR`. Empty all/any/threshold and slot extrema
are independently handwritten from the native CBOR schema.

Upstream license: Apache-2.0. Copyright 2024-2026 Biglup Labs; retain this notice
with derived vectors. Tests construct corresponding Haskell values rather than
merely forwarding opaque encoded script bytes. No wallet or network is involved.
