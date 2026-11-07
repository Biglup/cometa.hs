# Transaction inspection fixture provenance

Native baseline: `Biglup/cardano-c`, commit
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, Apache-2.0.
The native source is Copyright Biglup Labs; the repository `LICENSE` contains the
license. `Fixtures.Inspection` retains the project's Apache-2.0 notice.

`Fixtures.Inspection.fixtures` imports the complete transaction CBOR and expected
inspection JSON from every transaction inspection fixture in the pinned binding
corpus:

| Fixture | Native path |
| --- | --- |
| `conway-key-guard` | `lib/tests/vectors/bindings/v1/conway-key-guard.json` |
| `dijkstra-account-balances` | `lib/tests/vectors/bindings/v1/dijkstra-account-balances.json` |
| `dijkstra-signed-subtransaction` | `lib/tests/vectors/bindings/v1/dijkstra-signed-subtransaction.json` |

Only `transaction_cbor` and `inspection` are copied. Signing seeds, other key
material and unrelated fields are excluded. The expected JSON is compared as a
whole semantic `Data.Aeson.Value`; JSON object order is ignored, array order and
all field values remain significant.

Two complete native test pairs extend the domain coverage:

- `native-rich-babbage`: `lib/tests/transaction/transaction.cpp`, constant `CBOR`
  and the full expected JSON in
  `cardano_transaction_to_cip116_json.canConvertToCip116Json`. This covers native
  scripts, multiassets, bootstrap and key witnesses, Plutus scripts/data/redeemers,
  metadata and auxiliary data.
- `native-dijkstra-all-fields`: the complete CBOR and expected JSON in
  `cardano_transaction_to_cip116_json.preservesDijkstraFieldsAndNestedTransactions`
  in the same file. This covers nested subtransactions, guards, direct deposits,
  exact/range account intervals, V4 witnesses, auxiliary data and maximum unsigned
  64-bit decimal values.

Tests independently inspect every embedded subtransaction and body against its
complete corresponding expected JSON subtree, including subtransaction witnesses
and auxiliary data. The native function implementations are not copied into a
Haskell oracle.

Additional original tests construct arbitrary positive/negative Plutus integers
and nontext bytes through public Haskell values, verify exact source CBOR/body ID
and witness preservation, exercise malformed/trailing native input cleanup,
retain returned JSON through garbage collection, and invoke concurrent independent
operations. Ordinary fixtures need no credentials, network access or funded wallet
material. They establish inspection encoding agreement, not ledger validity.
