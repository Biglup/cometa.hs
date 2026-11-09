# Inspect Cardano values as JSON

Use `Cometa.Inspection` to obtain JSON domain views of transactions and standalone
Cardano values. The existing `Cometa.Transaction.Inspection` module continues to
provide the transaction and body operations. Each operation returns `IO (Either Error Value)` and reports
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

## Standalone values

The same inspection module provides named operations for values, scripts,
credentials, certificates, governance actions and proposals, pool parameters,
protocol updates, Plutus data, outputs, witnesses, resolved UTxOs, DReps, action
identifiers, anchors, voting procedures, metadata, auxiliary data, input references
and redeemers. Execution units, protocol versions and unit intervals retain their
exact integer components. Pool relays and metadata, constitutions, individual
voters and vote procedures, and verification/bootstrap witnesses also have named
inspectors. These inspect supplied fields without fetching URLs, resolving DNS,
checking voting eligibility or verifying signatures. Each accepts its corresponding typed
public value, performs no network queries and returns an owned `Aeson.Value`.
`Inspection.datum` additionally represents absence: `NoDatum` returns `Nothing`
without a native allocation; datum hashes and inline data return `Just` the
corresponding tagged JSON object.

`Inspection.script` includes a tagged wrapper. `Inspection.nativeScript` and
`Inspection.plutusScript` return its payload directly: native script conditions,
or the Plutus language and compiled bytes. Native-script inspection uses CIP-116
JSON; it differs from `Native.toJson`/`Native.fromJson` construction JSON.

`Inspection.value` allows signed native-asset quantities within signed 64-bit
bounds, while Ada must be nonnegative. A transaction output uses the stricter
validated `Output` type. Invalid or overflowing native quantities fail before
inspection. `Inspection.plutusData` retains arbitrary integer meaning, map order
and duplicate map keys in the JSON representation.

Standalone results use the same field schemas as those nested inside transaction
inspection. This does not make a standalone subtype interchangeable with a tagged
parent wrapper or make JSON an exact replacement for the original CBOR.

`Inspection.metadatum` and `Inspection.metadata` use CIP-116 tags and ordered
label/value arrays. They are separate from the plain and detailed JSON codecs in
`Cometa.Metadata`. Nested metadata maps retain duplicate keys and pair order.
`Inspection.auxiliaryData` includes metadata and auxiliary scripts while keeping
the exact source bytes and auxiliary-data hash unchanged.

For an ordinary list whose native schema is a plain JSON array, traverse the
corresponding element inspector and render the resulting list with Aeson. Native
script lists, certificate sets, redeemer lists, input/output collections, datum
sets and verification/bootstrap witness sets use those array schemas; no
additional collection-specific interface is needed. Metadata lists and maps have
tagged schemas: inspect `Metadata.list values` or `Metadata.map pairs` as a
metadatum instead.

## Protocol collections and Dijkstra account requirements

`Inspection.costModel` returns an ordered array of decimal cost strings; its
language identifier belongs to the surrounding model map. `Inspection.costModels`
returns named `plutus_v1` through `plutus_v4` fields. This native inspection schema
omits unknown language identifiers even though `CostModels` retains them. Inspect
an individual future-language model with `costModel` when its costs matter; use
the original CBOR for complete interchange. Inspection leaves the source model
map unchanged.

Execution prices and pool/DRep voting thresholds have named inspectors. Prices
may exceed one lovelace, and rational components remain unreduced: a supplied
`6/4` is represented by numerator `"6"` and denominator `"4"`. Threshold records
retain each named field separately. `Inspection.proposedUpdates` inspects legacy
genesis-authorized changes as a hash-keyed object; `Inspection.updateProposal`
adds the epoch, represented as a JSON number. These views do not establish era
eligibility or authority to update protocol parameters.

`Inspection.balanceInterval` distinguishes an exact balance from a range with
an inclusive lower and exclusive upper bound. Balances use decimal strings;
absent bounds become null. The native schema rejects a range with both bounds
absent. It describes reversed bounds without proving the requirement satisfiable.
`Inspection.balanceIntervals`, `directDeposits` and `requiredGuards` accept the
same validated `Fields.Entries` values used to assemble a transaction body. They
return ordered arrays of `key`/`value` objects. Account keys use reward-address
text; deposit zero remains `"0"`. Guard keys use tagged credentials and absent
script data becomes null. Inline script-data maps retain duplicate entries and
pair order. These are the same schemas nested in top-level and subtransaction
body inspection.

## Assets, digests and collection boundaries

`Inspection.assetName` renders a validated name as lowercase hexadecimal; the
empty name remains an empty string and arbitrary bytes need no text encoding.
`Inspection.blake2bHash` renders any validated nonempty digest in hexadecimal.
`Inspection.hashes` returns an array ordered by digest byte length, then bytes,
retaining duplicates. It does not infer a digest's role or recompute it.

Choose the asset schema explicitly. `Inspection.assets` takes associations of
`PolicyId` and asset-name/quantity associations, returning an object keyed by
hexadecimal policy and name. `Inspection.assetEntries` takes the same input and
returns ordered `{script_hash, assets}` records; each record's `assets` remains a
name-keyed object. `Inspection.policyAssets` inspects just name/quantity
associations as an object. `Inspection.policyAssetEntries` renders those
associations as ordered `{asset_name, amount}` records instead.

These functions retain explicit zero quantities, empty names and empty policy
groups. Quantities are decimal strings and must fit signed 64 bits; overflow
returns `InvalidValueQuantity`. Policy entries sort by policy bytes; asset entries
sort by name byte length, then bytes. Repeated names retain their input order in
`policyAssetEntries`. Repeated policy groups in either policy schema use the last
group, matching native map decoding. Object schemas cannot represent repeated property names in
`Aeson.Value`: all three schemas containing name-keyed objects reject repeated
asset names in retained groups with `InvalidValueCbor`.
Use `policyAssetEntries` when those repeated associations matter.

`Inspection.blsKey` describes a pool's 96-byte public key and 48-byte possession
proof without verifying either. `Inspection.committeeMembers` describes ordered
cold credentials and decimal expiry epochs. `Inspection.withdrawals` accepts
reward-account/amount associations, including zero and repeated accounts, and
returns ordered key/value records. Its order follows encoded address bytes,
while redeemer indices use the separately documented ledger account order.

`Inspection.guards` preserves the supplied credential order and rejects repeated
credentials. `Inspection.subTransactions` preserves supplied intent order and
rejects repeated body identifiers, including intents with different witnesses
for the same body. Both accept an empty list and return an empty JSON array.
These checks matter: traversing an element inspector over an arbitrary list does
not establish valid guard or subtransaction collection semantics.

Other existing ordered domain collections can use ordinary traversal. A committee
removal list from `Action.removalsToList` already has the native credential order;
inspect each credential. A pool's validated owner set has ascending 28-byte hashes;
inspect those as digest strings. Relay lists, proposal lists and each Plutus
language's script lists retain their order and duplicates. Plutus scripts use
`Inspection.plutusScript`, which renders the language/bytes payload; the generic
`Inspection.script` adds an extra wrapper. Script-data constructors, lists and
maps instead use `Inspection.plutusData` and keep their tagged schemas, including
ordered duplicate map entries.
