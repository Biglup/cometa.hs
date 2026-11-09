# Independent fee and accounting properties

`AccountingReliability.hs` adds four generated properties and a fixed rounding
regression through public bindings, with no new dependencies. No upstream code,
generator or fixture was copied.

## Gap audit against existing tests

`TransactionAccountingProperties` already checks generated certificate/proposal
and withdrawal totals, signed mint conservation, one outer plus one local intent,
and pool identities with repeated identical pool parameter records. The new
properties do not add another copy of those equations. ContextualTransaction
checks lookup/order/authority rather than fees. TransactionBuilding already has
fixed fee, size, execution and pool examples, but some expected values call
native fee/size oracles; it does not generate witness23/24 boundaries, reference
payload partitions, several intent execution rounding, or changing pool
registration contents with retirement interleaving at signed accumulator limits.

## Pinned primary upstream sources actually reviewed

All cardano-ledger paths below are from commit
`7827506b7518284d7f9dbbe3502a20431e513fe9`, Apache-2.0. Primary URLs are
`https://github.com/IntersectMBO/cardano-ledger/blob/7827506b7518284d7f9dbbe3502a20431e513fe9/`
followed by the exact paths below. Source files were fetched directly from that
commit for this review. The Apache-2.0 license was reviewed alongside them.

- `eras/alonzo/impl/src/Cardano/Ledger/Alonzo/Tx.hs`:
  `toCBORForSizeComputation` encodes the three-member envelope
  `[body,witnesses,auxiliary-data-or-null]`, omitting the validity Boolean;
  `alonzoMinFeeTx` combines linear size charge with one fee on all execution units.
- `libs/cardano-ledger-core/src/Cardano/Ledger/Plutus/ExUnits.hs`: `txscriptfee` rounds the
  combined memory/step rational charge upward once. The Alonzo Scripts module
  re-exports this implementation.
- `eras/conway/impl/src/Cardano/Ledger/Conway/Tx.hs`: `tierRefScriptFee` prices
  bytes in fixed-stride exponentially increasing/decreasing rational tiers and
  floors the entire sum once. Test oracle instead assigns each byte its marginal
  tier rate; it does not copy that upstream tier-loop implementation or the
  native checked mixed-number/coarsening algorithm.
- `eras/conway/impl/src/Cardano/Ledger/Conway/UTxO.hs`: produced/consumed values
  delegate to Mary accounting, while treasury donation is an additional produced
  coin term. This scopes accounting independently of witness/script admission.
- `eras/mary/impl/src/Cardano/Ledger/Mary/UTxO.hs`: produced value takes a
  predicate keyed by pool identity; consumed value includes withdrawals/refunds
  and positive mint, while negative mint is produced burn.
- `eras/shelley/impl/src/Cardano/Ledger/Shelley/UTxO.hs`: `produced` supplies pool
  registration membership from a map keyed by pool identifier; produced value
  includes outputs, fee and deposits. The identity is not the complete mutable
  pool parameters record. Native Cometa cannot supply existing chain state, so
  its documented batch contract charges each observed operator once instead.

Pinned upstream tests were reviewed to distinguish arithmetic from admission:

- `eras/conway/impl/testlib/Test/Cardano/Ledger/Conway/Imp/CertsSpec.hs`: withdrawals from an
  unregistered or wrong-network account fail state/witness conditions. A correct
  arithmetic sum alone therefore does not imply ledger acceptance.
- `eras/dijkstra/impl/testlib/Test/Cardano/Ledger/Dijkstra/Imp/SubUtxowSpec.hs`: pool registrations
  require the owner witness; staking unregistration uses the stored deposit and
  credential witness. These are real ledger-context obligations deliberately
  outside standalone fee/accounting snapshots. No such stateful test is imported
  or claimed to execute through Cometa.

## Independent expectations and supported generated domain

### Linear fee

Builds real typed witnesses with unique 32-byte keys/64-byte signatures and
metadata optionality. These are structurally valid byte lengths, not claims of
curve-point/signature validity. Counts 0,1,2,22,23,24,25 cross the witness list
header boundary; metadata byte counts 0,1,23,24,63,64 and body fee amounts cross
CBOR width boundaries. The oracle is

`constant + coefficient * (1 + bodyBytes + witnessBytes + auxBytesOrNull)`.

Lengths come from separately observable public constituent bytes. No full
transaction size or native fee helper supplies the expected answer. Flipping
the script-validity flag must preserve the fee, and the original transaction's
exact encoding remains unchanged. This covers fresh definite frames, not a
claim about every historical/nonminimal transaction envelope.

### Reference tiers and partition invariance

Each byte index j contributes `price * multiplier^(j div stride)` as an exact
Haskell Rational; the total is floored once. Generated strides 1,2,5,23,24,64,
zero/exact-boundary/+/-1 sizes and up to six tiers exercise rounding and the
zero-price case. Multipliers 1/2,1,3/2,6/5 cover decreasing, constant and increasing
rates without unsafe zero denominators. Prices are small bounded rationals.
Reference scripts are arbitrary nonempty Plutus V2 byte programs, because this
native fee path prices stored bytes without executing UPLC. Distinct resolved
UTxO identities partition one total payload at generated cut points; each
partition and a single contiguous payload must match the independent byte-rate
sum. This catches per-script rounding or tier-reset bugs. Actual UPLC validity,
script admission and transaction size limits are not asserted.

### Native whole-batch execution fee

Generates one outer group and up to four local intent groups of declared
memory/step budgets. Nonmonetary validity-start fields keep local body identities
distinct even when budget lists shrink to equal/empty values. Every nonempty
witness group uses distinct redeemer indices, and no scripts are executed.
The oracle sums raw generated memory/step charges over every group and takes
one ceiling. Linear fee parameters and reference byte price are zero, isolating
the actual native execution contribution inside `Building.minimumFee`; neither
Building.executionFee nor native pricing helpers supply an expected result.
The fixed case has four separate half-unit memory charges: native total must
be 2 rather than four individually rounded charges. Classifications record cases
where separate intent rounding would overcharge. Empty nested sets are absent,
not invalid Just-empty fields. Native minimum-fee resolution is exactly empty
because there are no spending/reference inputs.

### Pool updates, retirements and many bodies

Generates two through five total bodies with registration/retirement events over
four raw pool IDs. Every registration occurrence varies pledge/cost by body and
position, so duplicate operator identities do NOT disappear as byte-identical
certificates before accounting. Expected batch produced coin is
`number of distinct generated registered IDs * deposit`; retirement has no
immediate refund. Exact top-level deposits are also checked separately.
The oracle consumes generated IDs, not decoded certificates or native results.
Nonmonetary validity-start values ensure distinct local body IDs. Large deposits
are bounded by `INT64_MAX / max(1,total registration occurrences)`, keeping even
an undeduplicated intermediate total signed-safe; a wrong dedup result therefore
fails numerically rather than entering native overflow. 0/1/23/24/65536 and
near-signed-limit deposits are included. Tags, counters, syntax and actual chain
registration/refund state are not interpreted as admission tests.

No mint field is constructed by these tests, avoiding the previously found
Just-empty mint shrink case. All generators retain valid independent snapshots
when shrinking. Original transaction bytes are compared after native calls.
