# Inject evaluation and signing

`Cometa.Evaluation.Evaluator` is a record containing an `IO` function. Supply your
application's evaluator, then call `Evaluation.evaluate` with the target, complete
transaction and additional resolved UTxOs. The helper checks the target, rejects
duplicate resolved references, invokes the function and checks that its result
contains exactly the requested redeemer identifiers. Additional UTxOs supplement
any input-resolution capability your evaluator already has; the helper does not
require every input to appear in that list.

An identifier pairs a script purpose with its zero-based position in the
corresponding body collection. `Evaluation.mkBudgets` rejects duplicate identifiers
and sorts the result by purpose and index. Each budget contains unsigned memory
units and CPU steps. A successful result supplies exactly one budget per redeemer
at the selected level; an empty redeemer collection requires an empty result.
Missing or unknown identifiers return `InvalidEvaluationResult`.

Use `TopLevel` for outer witnesses or `SubTransaction index` for a zero-based
sub-transaction position. The evaluator receives the complete enclosing
transaction for either target. An out-of-range position fails before dispatch.
Your implementation can explicitly reject targets it does not support.

Evaluation returns budgets without changing the transaction or its script
arguments. Installing budgets, recomputing script-data commitments and fees,
and balancing the final transaction are separate building steps. This interface
makes no promise of execution logs or partial per-script success. Expected
failures use `Either Error`; thrown exceptions retain ordinary `IO` behavior.

## Evaluate scripts locally

Use `Cometa.Evaluation.Native.evaluator` when the application has compiled scripts,
resolved UTxOs and protocol context. Construct `Native.Config` with the network's
`SlotConfig`, protocol major version and `CostModels`. Supply actual chain cost
models for chain-equivalent budgets; a missing language model uses the VM's
version defaults. Model vectors must have the shape expected by their language
and protocol version; invalid models return a native error.

Call `Evaluation.evaluate` with this evaluator, the target, complete transaction
and resolved UTxOs. Every spending and reference input at every transaction level
must resolve; duplicates are rejected and extra resolved UTxOs are allowed.
Explicit validity slots must lie within the schedule and convert to unsigned
64-bit Unix milliseconds. This checks phase-2 execution, not complete ledger
admission or the freshness of the supplied snapshot.

Selecting `SubTransaction index` changes only the returned budget collection.
Each call deserializes and evaluates the outer transaction and every
sub-transaction, so a failure elsewhere also fails the selected target. All
levels share a limit of 100,000,000 memory units and 100,000,000,000 CPU steps;
these limits are fixed by the VM, independent of protocol transaction limits.
Each request runs anew with a fresh shared budget. V1–V3 scripts run at the outer
level; sub-transactions require V4. Language and builtin availability also depend
on the protocol major version. Older languages also reject transaction fields
that their context cannot represent: V1/V2 cannot carry governance fields, and
V1–V3 cannot carry the new Dijkstra account and guard requirements.

A malformed or unavailable script reports `NativeError` with `DecodingFailure`;
a script that executes unsuccessfully reports `ScriptEvaluationFailure`. The
error retains a diagnostic. Evaluation is all-or-error and does not expose
execution logs. Budgets do not replace redeemer arguments or modify any original
transaction bytes, including imported encodings.

This executable offline example runs an actual V4 minting script. Its minimal
transaction is an execution fixture, not a balanced transaction for submission.

```{literalinclude} ../../examples/NativeEvaluation.hs
:language: haskell
:start-at: import qualified Cometa.AssetId
```

## Sign with an injected signer

`Cometa.Signer.Signer` similarly wraps partial signing. `Signer.ed25519` captures
an open Ed25519 key, `Signer.software` captures an Ed25519 software handler, and
`Signer.bip32` captures a BIP32 handler with nonempty derivation paths. Keep the
key or handler scope open while using the closure. A closure used after scope
exit reports the existing closed-key or closed-handler error. These adapters
reuse the existing signing operations without exporting private keys.

A signer returns additional witnesses. Merge them explicitly using
`Transaction.addWitnesses`; this preserves the exact body encoding and reports
signature conflicts. Signing does not submit a transaction.

The following offline example injects a deterministic evaluator test double and
an unfunded demonstration key through one error boundary. It demonstrates
composition, without applying the returned budgets or claiming a balanced or
ledger-valid transaction.

```{literalinclude} ../../examples/Evaluation.hs
:language: haskell
:start-at: import qualified Cometa.Crypto
```
