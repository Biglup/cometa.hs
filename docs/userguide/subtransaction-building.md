# Build and sign a sub-transaction intent

Build a `Cometa.SubTransaction.Plan` from explicit resolved spending inputs,
reference inputs and outputs, then call `Cometa.SubTransaction.Builder.build`.
Configure complete protocol parameters, a slot schedule and `Fields.Testnet` or
`Fields.Mainnet`. The body network is distinct from an address's network tag and
from network magic.

A sub-transaction is an intent. Building spends exactly the requested inputs and
creates exactly the requested outputs, adding no fee, collateral, change or
wallet selection. The intent can have a surplus or deficit. Sign its own body
with `Signing.signSubTransaction`, then attach it to an outer plan with
`Plan.attachSubTransaction signedIntent (SubPlan.resolvedInputs intent)`.
The outer builder balances the complete batch and supplies its fee and
collateral. Signing and submitting the enclosing transaction remain separate.
Use `Building.subTransactionImbalance` to inspect an intent's deficit or surplus
and `Building.isBalanced` to check conservation in the complete batch.

Common plan operations cover payments, native/Plutus minting, datums, scripts,
certificates, withdrawals, metadata and validity bounds. Dijkstra operations add
key or script guards, required outer guards, direct account deposits and account
balance intervals. Governance operations accept typed actions, anchors, voters
and voting procedures; proposal deposits come from the protocol snapshot.
Parameter-change and treasury-withdrawal proposals may name a guardrails policy.
When they do, supply its Plutus V4 script witness or reference script.
`SubPlan.propose` supplies the unit redeemer `Constr 0 []`;
`SubPlan.proposeWithRedeemer` accepts an explicit argument, and
`SubPlan.proposeWithDeferredRedeemer` derives it from the local draft. The latter
two operations require an action naming a policy. Proposals without a policy
create no proposing redeemer.
Conflicting input snapshots or arguments fail at the build boundary. Quantities,
aggregates and deposits must fit the native signed range. Results must fit the
configured transaction size and execution-unit limits, and output values must
fit the configured value size. These checks do not establish chain freshness or
complete ledger admission; later signatures and enclosing fields also consume
transaction space.

Deferred arguments observe a local draft with zero fee, sorted local spending
inputs and local redeemer indices. Each registered callback runs once when this
intent is built. It receives the canonical resolved spending inputs; reference
inputs appear in the draft body but are absent from that spending list. The
callback is pure and deterministic, returning `Either Error EncodedPlutusData`.
A failure aborts the build; thrown exceptions propagate after cleanup.
Group several minted names under one policy or several votes under one voter to
share one deferred argument. Register each deferred policy or voter once; empty
or entirely cancelled groups invoke no callback.

Executed sub-transaction scripts require Plutus V4. Building evaluates them in a
minimal enclosing batch at position zero and commits the resulting budgets and
script-data hash. A script that depends on its actual position or surrounding
batch can need different budgets or fail in the final batch. Local deferred
arguments do not run again when the signed intent is attached to an outer plan.
The outer builder evaluates each attached intent in the complete batch and
checks that its actual execution fits its declared budgets. It preserves the
signed intent's bytes; insufficient budgets fail the outer build. Revise the
intent and sign its updated body again before retrying. An injected evaluator
must support `SubTransaction index` targets as well as `TopLevel` for batches
carrying scripted intents. Choose arguments and scripts whose intended local
meaning survives assembly.

This offline example derives a demonstration address, builds and signs a local
intent, attaches it to a funded outer plan, balances and signs the batch, and
checks complete value conservation. All references and funds are synthetic.

```{literalinclude} ../../examples/SubTransactionBuilding.hs
:language: haskell
:start-at: import qualified Cometa.Address
```
