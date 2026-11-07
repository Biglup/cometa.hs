# Transaction construction coverage

The target is every construction supported by the pinned cardano-c transaction
model, with balancing conveniences for normal wallet workflows. Low-level body
and witness assembly remains available for imported, historical and externally
balanced transactions. A builder is not a ledger validator.

## Construction surfaces

| Capability | Haskell surface | Acceptance tests |
| --- | --- | --- |
| Inputs, ordered outputs, fees, network and validity interval | `Transaction.Body`, `Fields`, `Plan`, `Builder.Config` | `TransactionBody`, `TransactionBuilder`, `PublicTransaction` |
| Multi-assets, native/Plutus minting and burning | `Value`, `Script`, `Plan.mint*` | `Value`, `Scripts`, `DeferredRedeemer`, `NativeWorkflows` |
| Datum hashes, inline/witness datums and reference scripts | `Transaction.Datum`, `Output`, `Plan` | `TransactionBuilder`, `NativeWorkflows`, `SubTransactionBuilder` |
| Collateral inputs, return and total; native balancing | `Transaction.Body`, `Builder.Config` | `TransactionBuilding`, `TransactionBuilder`, `NativeCoinSelection` |
| Metadata and auxiliary scripts/data commitments | `Metadata`, `AuxiliaryData`, `Transaction` | `Metadata`, `TransactionWitnesses`, `PublicTransaction` |
| Every certificate and pool parameter alternative | `Certificate`, `Pool`, `Plan.certificate*` | `Certificates`, `Pool`, `ConnectedGovernance` |
| Withdrawals, including zero script withdrawals | `Fields`, `Plan.withdraw*` | `DeferredRedeemer`, `NativeWorkflows`, `ConnectedGovernance` |
| Conway votes and all seven governance actions | `Governance`, `Plan.vote*`, `Plan.propose*` | `Proposals`, `DijkstraBuilder`, `ConnectedGovernance` |
| Current treasury assertion and donations | `Fields`, `Plan.currentTreasuryValue`, `Plan.donate` | `DijkstraBuilder` |
| Immediate/deferred spend, mint, certificate, withdrawal, vote and proposal redeemers | `Plan`, `SubTransaction.Plan`, `Transaction.Indices`, `SubTransaction.Indices` | `DeferredRedeemer`, `DijkstraBuilder`, `SubTransactionBuilder`, `ContextualTransaction` |
| Dijkstra guards and parent guard requirements | `Plan`, `SubTransaction.Plan`, `Fields` | `DijkstraBuilder`, `SubTransactionBuilder`, `NativeEvaluation` |
| Direct deposits and current/starting balance constraints | `Plan`, `Fields`, `Transaction.Body` | `TransactionBody`, `DijkstraBuilder`, `SubTransactionBuilder` |
| Independently signed intents and enclosing batches | `SubTransaction`, `Transaction.Signing`, `Plan.attachSubTransaction` | `SubTransactionBuilder`, `DijkstraBuilder`, `ContextualTransaction` |
| Key/bootstrap/script witnesses; explicit merge and external signing | `Transaction.Witnesses`, `Signing`, `Signer` | `TransactionWitnesses`, `SoftwareKeyHandler`, `PublicTransaction` |
| Legacy updates, original CBOR and collection-tag preservation | `Protocol.Updates`, `Transaction.Body`, exact encoded values | `TransactionBody`, `Parameters`, `PublicTransaction` |

The rows identify concrete tests, not a percentage or a claim that every possible
combination has been exercised. Native conformance catches representation and
binding errors; independent vectors and ledger submission provide different
evidence. Existing preprod results are recorded in [example parity](EXAMPLE_PARITY.md).
Dijkstra builds remain offline until a suitable network is available.

## Current proposal completion

A proposal's insertion position determines its proposing redeemer index, including
preceding proposals without policies. Plans obtain the deposit from the protocol
snapshot. A guardrails policy can use the default unit argument, an explicit
argument, or a deterministic callback over the balanced draft. Actions without
policies do not request evaluation. Conflicting treasury assertions and duplicate
proposals fail at the build boundary, before callbacks run.

Current treasury value is a statement about ledger state, not transaction input
value. Explicit zero and the full unsigned range are preserved. It belongs to the
top-level body; subtransaction plans do not expose this operation.

## API design evidence

Before extending the plan API, reviewed cardano-api
[`c2212851`, Tx/Internal/Body.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs):
`mkTxProposalProcedures`, `indexWitnessedTxProposalProcedures` and
`setTxCurrentTreasuryValue`. The source associates optional script witnesses with
ordered proposals and counts un-witnessed proposals in indices. Cometa follows
those domain rules through its existing ordered plan monoid, with explicit and
deferred variants matching its other script purposes. It does not introduce an
era-indexed body GADT or require a new effects framework for ordinary construction.

Standalone credential/hash CBOR complements the existing checked byte constructors
and follows the same `encodeCbor`/`decodeCbor` convention already used by the domain
modules. Unlike imported transaction bytes, these semantic values produce fresh
canonical encodings and make no original-CBOR identity claim.

## Remaining native surface audit

This slice completes the identified treasury/proposing builder gaps. It does not
claim complete native function coverage. The remaining coherent serialization
work is:

- Standalone per-policy asset-name quantity maps, withdrawal maps (including
  empty maps), and variable-length hash sets. Reuse Haskell values without
  introducing mutable C collection wrappers; specify zero/duplicate/order rules.
- Explicit tagged/untagged fresh set encoding and observation of individual
  collection tags. Retaining imported bytes is not equivalent to choosing new
  encodings. Body edits must preserve the existing signature invalidation policy.
- Remaining standalone CIP-116 leaf values and collection shapes. Ordinary
  traversal suffices for native array schemas only after their exact shape and
  ordering are verified; the ledger keeps other outputs pending.
- A deliberate contract for cache normalization and standalone contextual
  rebalancing. Existing plan building and exact-byte imports alone do not establish
  those workflows.

Generic mutable buffers, reader/writer cursors, native reference counts and raw
JSON machinery do not need public Haskell object wrappers. Reconciliation uses
specific ByteString, Integer, cborg and Aeson operations where contracts match;
unreviewed details remain pending. In particular, native variable-length buffer
and hash ordering compares length first, while Haskell ByteString ordering is
lexicographic. Explicit zero entries, duplicate JSON keys and numeric lexical
forms are not silently declared equivalent to normalized Haskell values.
