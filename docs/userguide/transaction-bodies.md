# Assemble and reload transaction bodies

`Cometa.Transaction.Input`, `Output`, `Datum`, `Fields` and `Body` provide owned
values for transaction references, resolved outputs and complete body data.
Construction and inspection are pure. `Body.hash` computes BLAKE2b-256 in `IO`.
The compiled `examples/TransactionBodies.hs` assembles a payment-shaped body,
reloads its exact bytes and prints the identifier. Its hashes are demonstration
data; it does not query a network, select coins or establish that an input exists.

Validate the transaction identifier, destination and output quantities once,
then assemble the required body fields:

```haskell
let reference = Input.input previousId 0
output <- Output.mkOutput destination (Value.lovelace 2000000) Datum.NoDatum Nothing
let minimal = Body.body [reference] [output] 170000
    validity = (Body.bodyFields minimal)
      { Fields.fieldInvalidBefore = Just 100
      , Fields.fieldInvalidAfter = Just 200
      }
encoded <- Body.fromBody (minimal {Body.bodyFields = validity})
reloaded <- Body.decodeCbor (Body.toCbor encoded)
```

The example's qualified imports show the complete workflow and one `Either Error`
boundary for validation, assembly and reloading. Monetary quantities are integer
lovelace or native-asset units. Output quantities are nonnegative and at most
`2^63 - 1`. References carry a 32-byte
transaction identifier and a zero-based unsigned 64-bit index. A body fee uses the
full unsigned 64-bit range. These representation bounds do not establish minimum
Ada, fee sufficiency, balance, authorization or era eligibility.

`Datum.NoDatum`, `Datum.DatumHash` and `Datum.InlineDatum` make the output datum
choice explicit. A hash is exactly 32 bytes; it does not carry a witness datum.
An inline datum uses `PlutusData.EncodedPlutusData` so its exact encoding survives
body assembly. Outputs can include an optional typed reference script. Output
decoding accepts legacy arrays and current maps. `Output.EncodedOutput` retains
an imported output's exact bytes independently of semantic fields.

`Cometa.Address.Address` distinguishes Shelley, Byron and reward-address forms.
Representing a reward address does not assert ledger acceptance as an output
address. Pointer-address components use unsigned 32-bit values. Wider imported components are
rejected explicitly; they never silently change when inspected or rebuilt.

The `Fields` record carries validity slots, certificates, withdrawals, mint/burn
instructions, guards, network, reference inputs, voting, proposals and treasury
fields. `Fields.mkMint` validates signed native-asset quantities and rejects Ada.
`Fields.mkEntries` validates nonempty unique-key associations and rejects repeated
keys even when their values agree. Fresh encoding sorts input references by
transaction hash and index, retaining duplicates; output order determines output
indices. Association encodings sort by their encoded keys. Optional fields retain
absence separately from a present zero or an allowed empty collection.

Top-level body fields add legacy updates, collateral, collateral return and total,
Dijkstra subtransactions, and starting account-balance conditions. Dijkstra shared
fields include required top-level guard credentials with optional exact datum,
direct deposits and exact/range account-balance conditions. Range lower bounds are
inclusive and upper bounds exclusive. `Cometa.SubTransaction.Body` exposes the
separate sub-body schema: it excludes fees, legacy updates, collateral, nested
subtransactions and starting-balance conditions. Its encoder rejects present empty
certificates, mint and guards. Fresh bodies reject duplicate or empty guard sets;
imported historical top-level empty guard encodings remain available exactly.
A present subtransaction collection must be nonempty.

`Body.encodeCbor` and `Body.fromBody` validate these body-specific constraints.
They produce a fresh definite encoding. `Body.decodeCbor` accepts the complete
supported body schema, rejects unknown or repeated keys and trailing bytes, and
returns `EncodedBody`. Use `Body.toCbor` when storing, transmitting or signing an
imported body: alternative map order, integer widths, optional set tags and nested
hash-bearing encodings contribute to its identifier. Reassembling inspected
semantic fields can produce a different identifier.

`Body.setFee` edits semantic fields for fresh assembly. `Body.setFeeEncoded` edits
only the fee of an imported validated body while retaining every other exact
field slice. An unchanged fee preserves the whole original body encoding. A
changed fee uses a fresh outer map and requires renewed signatures. The original
snapshot remains independent. Transaction envelopes handle witness invalidation
as described in [transactions](transactions.md).

`Cometa.Transaction.Utxo` pairs a reference with its resolved semantic output.
Its `[input, output]` CBOR is a snapshot interchange format. Constructing a snapshot
does not query chain state or prove that the output is still unspent.
