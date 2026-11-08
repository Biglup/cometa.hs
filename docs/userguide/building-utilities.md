# Calculate transaction costs and commitments

`Cometa.Transaction.Building` provides independent calculations for callers who
assemble or inspect transactions. None of these operations builds, signs,
evaluates or submits a transaction, and none changes its inputs.

```{literalinclude} ../../examples/BuildingUtilities.hs
:language: haskell
:start-at: module Main
```

The example calculates minimum output Ada and the linear fee for an unsigned
transaction fragment. Its coefficients are demonstration values. Obtain a
current protocol snapshot for actual transaction construction.

## Output Ada and fees

`minimumAda costPerByte output` calculates the lovelace an output needs,
including the effect of its coin encoding on output size. It returns the required
coin amount; it does not update the output. Arithmetic overflow is an error.

`baseFee constant coefficient transaction` calculates only the linear size fee.
`minimumFee parameters resolvedInputs transaction` additionally prices
execution units and reference scripts. Supply unique resolved UTxOs covering
exactly the union of spending and reference inputs across the outer body and
subtransactions. Reference scripts attached to spent outputs also incur a fee,
even when the script does not run. A UTxO used both ways within one body is priced
once. The same UTxO appearing in several bodies is priced for each body.
The latter function checks that coverage, but it does not fetch missing inputs or
execute scripts.

Both functions use the witnesses already present. Adding signatures or changing
execution budgets can change the fee. Use the transaction builder when you need
witness estimation, input selection, change and fee balancing together.

`referenceScriptFee parameters resolvedReferences` prices the scripts in the
specified unique outputs. Unlike `minimumFee`, this independent function has no
transaction against which to check the reference list.

## Sizes and execution budgets

`coinSize`, `outputSize`, `scriptSize` and `transactionSize` inspect existing
owned values without native effects. Sizes are bytes. `transactionSize` includes
the validity flag when present; `baseFee` uses the ledger fee size, which excludes
that flag. `scriptSize` measures exact native-script CBOR or compiled Plutus bytes,
excluding the reference-script language envelope and the outer Plutus bytestring.

`totalExecutionUnits redeemers` sums declared memory and CPU budgets with checked
unsigned 64-bit totals. Include nested redeemers explicitly when inspecting a
batch. `executionFee prices total` calculates the ceiling of the exact combined
memory and CPU charge once. It excludes reference-script fees and does not run
scripts. Totals and fees report overflow instead of wrapping.

## Script-data commitments

`scriptDataHash costModels witnesses` returns the script-data hash, or `Nothing`
when there are no redeemers or datums. Supply cost models only for the languages
used by the transaction. Every supplied language view contributes when redeemers
are present. Datum-only witnesses use an empty redeemer collection and no
language views. Exact datum and redeemer encodings matter to the commitment.

`CostModels.encodeLanguageViews` exposes the language-view CBOR used for this
commitment. V1 retains its historical bytestring-wrapped indefinite cost array;
V2 through V4 use ordinary cost arrays. Unknown language identifiers do not
contribute. Supply only the languages actually used by the transaction.

The result does not update the body's script-data-hash field. Recompute it when
redeemer arguments, execution budgets, datums or relevant cost models change.

## Deposits and refunds

`implicitCoin parameters transaction` reports deposit charges and reclaimable
coin for the outer body. `subTransactionImplicitCoin` calculates the same values
for one subtransaction. These are body calculations, not queries of account or
registration state. They exclude minting and do not establish whether a refund
is currently available on chain. The outer calculation excludes nested bodies;
interpret batch-level effects in their transaction context.


## Check conservation across a batch

Use `Building.imbalance parameters resolved transaction` for the outer body,
`Building.subTransactionImbalance parameters resolved intent` for a local intent,
and `Building.batchImbalance parameters resolved transaction` for the complete
batch. A positive coin or asset quantity is surplus; a negative quantity is a
deficit. Intents can deliberately contribute surplus or deficit for the batcher
to match. `Building.isBalanced` checks that the whole-batch result is zero.

These calculations include withdrawals, deposits and refunds, minting/burning,
outputs, donation and direct account deposits. Only the outer body pays a fee.
Pool registration deposits are charged once per pool across the whole batch.
Resolve every spending input; additional resolved entries are allowed, but
duplicate entries are rejected. Reference and collateral inputs do not contribute
to conservation. The checks preserve the supplied transaction and witnesses.

Zero imbalance does not establish valid signatures, scripts, current input
availability or other ledger rules. See the [signed batching example](subtransaction-building.md)
for a complete offline workflow.
