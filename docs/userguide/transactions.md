# Inspect and sign transactions

A transaction owns its body, witnesses, optional auxiliary data and original
encoding. Decode stored CBOR once, inspect typed fields, then sign using a scoped
key. `examples/Transactions.hs` compiles this workflow with deterministic test
material and one `Either Error` boundary. It does not submit a transaction.

```{literalinclude} ../../examples/Transactions.hs
:language: haskell
:start-at: module Main
```

`Tx.transactionId` hashes the exact body bytes. Signing adds an Ed25519 witness
over that hash and retains existing partial signatures. Adding witnesses leaves
the body and its identifier unchanged, including nonminimal body encodings.
Historical three-field frames, four-field mempool frames, and Dijkstra block
field order are preserved, including indefinite outer arrays.

Use `Tx.body` with `Cometa.Transaction.Body.toBody` for inspection. `Tx.setFee`
changes the fee in lovelace. `Tx.setBody` accepts another exact encoded body.
A body equal under `Body` equality preserves every byte and signature. That
equality includes field presence, collection order and the exact encodings of
embedded identity-bearing data. A changed
body removes the outer verification-key and bootstrap signatures. Scripts,
datums, redeemers and auxiliary data remain; recheck their commitments and
transaction validity before signing again. Editing an enclosing body preserves
embedded sub-transaction bytes and their independent signatures.

For encrypted software storage, `Software.signTransaction` returns partial
witnesses from an Ed25519 handler. `Software.signTransactionAt` derives the
supplied nonempty collection of validated five-level paths from a BIP32 handler.
Each operation requests the password once. Merge the returned witnesses with
`Tx.addWitnesses`; conflicting signatures for the same verification key fail.
The handler's existing close, overlap, callback exception and cancellation
contracts apply to signing too.

`Cometa.SubTransaction` retains the three-field Dijkstra sub-transaction envelope.
`Signing.signSubTransaction` and the corresponding software-handler operations
sign its own body hash. Importing a transaction checks its data schema. It does
not verify signatures, execute scripts, balance values, authenticate auxiliary
data commitments or assert validity for a ledger era.

`Tx.assemble` attaches a supplied witness set and optional exact auxiliary data to
a body in a fresh mempool frame. `Tx.setAuxiliaryData` changes only the payload;
it does not alter the body's commitment. `Tx.setScriptValidity` changes the
claimed script result without changing the ID or signatures. Setting false on
a historical three-field frame promotes it to mempool order, because historical
frames cannot encode that claim.
