# Inspect transactions as JSON

Use `Cometa.Transaction.Inspection` to obtain a JSON domain view of a transaction
or one of its bodies. Each operation returns `IO (Either Error Value)` and reports
native conversion failures explicitly.

```haskell
view <- Inspection.transaction transaction
```

`Inspection.transaction` includes the body, validity flag, witnesses and optional
auxiliary data. `Inspection.subTransaction` uses the subtransaction schema, without
an outer validity flag or transaction fee. To inspect only a body, pass its exact
encoded wrapper to `Inspection.body` or `Inspection.subBody`.

The result uses the native CIP-116 inspection representation, including governance
fields and native extensions for nested transactions, guards and account balances.
Protocol integers such as fees and quantities use decimal strings, binary values
use text encodings, and maps can appear as ordered arrays of key/value entries.
This schema differs from transaction CBOR wrapped in a JSON string or text envelope,
and from the detailed metadata JSON codec.

Inspection leaves the original CBOR, transaction ID and signatures unchanged.
It does not validate a transaction against ledger state. JSON is a view for display,
diagnostics and comparison; retain the original CBOR for storage, hashing, signing
or exact interchange. There is no implicit global `ToJSON` instance that selects
this representation for every use of a transaction.

Use `Data.Aeson.encode` to render a successful result. The compiled offline example
constructs a small transaction and inspects its integer and byte-string datum:

```{literalinclude} ../../examples/TransactionInspection.hs
:language: haskell
:start-at: module Main
```

The native extensions are inspected consistently with the pinned native library;
they do not imply that a published CIP-116 schema covers every newer ledger field.
JSON object key order is insignificant, while array order remains observable.
