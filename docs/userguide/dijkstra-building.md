# Build governance transactions and batches

Transaction plans compose governance instructions with payments. Assemble a
validated governance action, return account and metadata anchor, then append it
with `Plan.propose`. The protocol snapshot supplies the proposal deposit; the
builder includes it in the amount funded by the transaction. Proposal order is
preserved because positions determine proposal identities.

`Plan.vote voter action procedure` adds a key-authorized vote. Several actions
under one script voter share one voting redeemer. Declare them together with
`Plan.voteWithRedeemer voter votes argument`, or use
`Plan.voteWithDeferredRedeemer voter votes callback` when the argument depends on
the balanced draft. `votes` is a list of action/procedure pairs. Empty groups do
nothing. Identical votes compose idempotently; conflicting choices or competing
redeemer declarations fail at the build boundary.

Guards require a key signature or script authorization. Add a key or script
credential with `Plan.requireGuard`. A script guard with a Plutus argument uses
`Plan.guardWithRedeemer scriptHash argument`; attach its script explicitly. A
top-level Plutus guard uses V4 and can inspect the complete batch. Guard positions
retain insertion order, including key guards introduced by `Plan.requireSigner`.

Account operations describe ledger account constraints and transfers:

- `Plan.directDeposit account amount` funds a reward account without creating a
  UTxO. Amounts are positive lovelace and accumulate for the same account. Each
  amount and its combined total must fit the signed 64-bit native balance range.
- `Plan.accountBalance account interval` constrains the account when the outer
  transaction is applied. `Plan.startingAccountBalance account interval`
  constrains its balance before any subtransaction applies. Use
  `Fields.ExactBalance amount` or `Fields.BalanceRange lower upper`, whose lower
  bound is inclusive and upper bound exclusive. Repeated identical constraints
  are idempotent; differing constraints for one account fail when building.
- `Plan.donate amount` contributes lovelace to the treasury. Contributions add
  under composition and the total must fit the signed 64-bit balance range.

These account operations and script credential guards require a ledger era that
supports them. Building an offline transaction does not query account balances or
establish whether a governance action is eligible. Proposal building
requires guardrails policy hashes for parameter changes and treasury withdrawals;
use an explicit executable Plutus script hash in those `Action` values and
attach its script. These proposal operations supply the unit argument
`Constr 0 []` to the proposing script; they do not accept a custom argument.

`examples/DijkstraBuilding.hs` compiles an offline account and governance workflow
using synthetic inputs and one error boundary:

```{literalinclude} ../../examples/DijkstraBuilding.hs
:language: haskell
:start-at: module Main
```

A batch carries independently built and signed subtransactions. Add a complete
subtransaction with `Plan.attachSubTransaction sub resolvedInputs`. Supply the
UTxOs behind all spending and reference inputs. The builder retains its exact
bytes and signatures, funds the net batch deficit or returns its surplus in
change, and provides the outer fee and collateral. Inputs spent by different
transaction levels must be disjoint. Imported subtransaction validity endpoints
and output value sizes are checked against the supplied schedule and protocol
limits, just as values built locally are checked. Subtransaction spending and reference inputs
are excluded from the outer wallet and collateral candidates. The default
selector requires at least one outer spending input, so supply an independent
fee-payer UTxO even when the subtransactions have a net surplus.

A subtransaction may require guards on its parent; explicitly add those guards
to the outer plan. Script and datum authorization remains local where required:
attaching a signed subtransaction does not authorize changing its witnesses or
execution budgets. Before returning, the builder reevaluates each scripted
subtransaction against the completed enclosing transaction and rejects a budget
that is too small. It preserves the original subtransaction bytes. An injected
evaluator must support subtransaction targets as well as top-level targets.

A top-level transaction using legacy Plutus versions must
conserve value independently, so its subtransactions must balance among
themselves. Native errors describe violations of these requirements.

See `examples/SubTransactionBuilding.hs` for the complete subtransaction build,
sign and batch workflow.
