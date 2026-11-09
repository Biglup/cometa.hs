# Build a transaction

Assemble a `Cometa.Transaction.Plan` from owned values, then call
`Cometa.Transaction.Builder.build` once to obtain an unsigned transaction.
Payments keep their order and multiplicity. Repeated mint instructions add their
quantities; equal and opposite quantities cancel. Validity bounds intersect.
Conflicting spending requirements, metadata labels or reward withdrawals return
an error at the build boundary.

The builder takes complete protocol parameters, slot configuration, a change
address and resolved wallet outputs. These snapshots must describe the same
ledger state. You can obtain them through your provider, cache an appropriate
snapshot, or supply fixtures for offline tests.

```haskell
import qualified Cometa.Provider as Provider
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Plan as Plan
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)

buildPayment provider wallet output expiry = runExceptT $ do
  parameters <- ExceptT (Provider.protocolParameters provider)
  available <- ExceptT (Provider.utxosAt provider wallet)
  let config = (Builder.defaultConfig parameters Slot.preview wallet)
        {Builder.availableUtxos = available}
      plan = Plan.payTo output <> Plan.validUntil expiry
  ExceptT (Builder.build config plan)
```

`Slot.preview` in this example selects Preview time conversion. Choose the
configuration corresponding to your network. Supply `expiry` as an absolute
future slot on that network, allowing time to sign, submit and confirm the
transaction. The builder does not query the current slot. The change address
determines the transaction body's network tag. The builder calculates fees and change and uses
its built-in selector and evaluator by default. It returns errors for insufficient
funds, invalid requirements or balancing failures. The result has no key
signatures; use the [signing workflow](evaluation-and-signing.md) and submit it
explicitly through your provider.

For custom policies set `Builder.selector` to `Just selector` or
`Builder.evaluator` to `Just evaluator`. These are ordinary records of functions;
see [selection](coin-selection.md) and [evaluation](evaluation-and-signing.md).
A provider-backed evaluator can call `Provider.evaluateTransaction` within its
record. Callbacks can run repeatedly while balancing converges. Expected errors
are returned unchanged; exceptions propagate after cleanup, including ordinary
asynchronous cancellation.

`Plan.spend` takes a resolved key-controlled UTxO. For script spends,
`Plan.spendWith` takes the resolved UTxO, optional redeemer argument and optional
datum witness. Add script witnesses with `Plan.attachScript`, or supply reference
inputs with `Plan.referenceInput`. Supply eligible collateral through
`Builder.collateralUtxos`; `Builder.collateralChangeAddress` optionally chooses
its return destination. Evaluation receives the complete candidate transaction
and resolved inputs and provides budgets for its existing redeemers.

Other plan operations attach metadata, datums, staking certificates, reward
withdrawals and required key signers. `mintWithRedeemer`,
`certificateWithRedeemer` and `withdrawWithRedeemer` add Plutus arguments to the
corresponding operations. The builder checks signed 64-bit quantity
bounds before balancing, including aggregate sources and targets. Wallet and
collateral lists require unique input references. A mandatory spend may also
appear in the wallet snapshot; it is counted once. Complete transactions remain
subject to ledger rules and the state against which they are submitted.

The compiled offline example in `examples/TransactionBuilding.hs` builds a
payment using synthetic inputs and demonstration parameters. Run it with:

```sh
cabal run cometa-transaction-building
```

Validity slots must be representable by the selected slot configuration; an
endpoint before its reference slot or beyond its timestamp range returns an
error. Evaluation budgets must fit the supplied protocol limit. The builder also
checks the resulting transaction size with its required witness reserve. Set
`Builder.extraSigners` for additional signatures needed by native scripts so
that fee and size estimates include them.

## Governance proposals and treasury assertions

`Plan.propose returnAccount action anchor` takes its deposit from the configured
protocol parameters. Parameter-change and treasury-withdrawal actions may name a
guardrails policy. When they do, this operation uses the unit redeemer; attach the
script or resolve its reference-script UTxO separately. Actions without a policy
need no proposing witness.

Use `Plan.proposeWithRedeemer returnAccount action anchor argument` for an explicit
policy argument, or `Plan.proposeWithDeferredRedeemer` to derive it from the
balanced draft. These operations require an action with a guardrails policy.
Proposal order determines redeemer indices, including preceding actions without
scripts. `Transaction.Indices.findProposal` locates a complete proposal, including
its configured deposit. Duplicate proposals fail at the build boundary.

`Plan.currentTreasuryValue amount` declares the treasury balance in lovelace as a
ledger-state assertion. It does not fund the transaction or donate that amount.
Repeated identical assertions combine; conflicting values fail. Zero is preserved
explicitly. `Plan.donate amount` is the separate operation for contributing funds.

## Compose deferred redeemers

Use `Cometa.Transaction.Deferred` when an argument depends on positions in the
current builder draft. Compose a `Query` with ordinary `do` notation or
applicative operators, then provide your application's script-data encoding:

```haskell
import qualified Cometa.PlutusData as Data
import qualified Cometa.Transaction.Deferred as Deferred
import qualified Cometa.Transaction.Plan as Plan

-- reference and destinationOutput are previously validated public values.
let positions = (,) <$> Deferred.inputIndex reference
                    <*> Deferred.outputIndex destinationOutput
    encodePositions (input, output) =
      Data.Constr 0 [Data.Integer (toInteger input), Data.Integer (toInteger output)]
    argument = Deferred.redeemer encodePositions positions
    plan = Plan.spendWithDeferredRedeemer resolvedInput argument Nothing
```

Required lookups return `InvalidBuildingRequest` when an object is absent.
`outputIndex` compares the complete semantic output, including its inline datum
encoding, and requires a unique match. `outputIndexWhere` accepts a predicate
when your application identifies an output by selected fields; it also fails
when several outputs match. This avoids silently choosing one of two payments
to the same address. Other indices follow `Transaction.Indices` ordering and
first-duplicate rules. Redeemer rank is distinct from its authorized body-item
index. Certificate lookup uses native normalization and remains available through
the existing effectful `Indices.findCertificate`, outside these pure queries.

`Deferred.draft` exposes the current transaction and `Deferred.selectedInputs`
exposes the callback's selected spending-input snapshot. `Deferred.fromEither`
incorporates your own validation; the first error propagates unchanged. Test a
query with `Deferred.run query draft selectedInputs` before attaching it to a
plan. This runner uses exactly the supplied snapshot without validating or
reordering it.

`Deferred.encodedRedeemer` accepts a query returning `EncodedPlutusData` and
preserves its exact bytes. `Deferred.redeemer` instead takes an explicit encoder
from your query result to semantic `PlutusData`. Both produce the existing raw
callback type, which remains available for custom policies. The same callbacks
fit `SubTransaction.Plan`: queries inspect the supplied transaction draft's
body, without automatically descending into nested subtransactions.

Balancing may invoke a callback several times with changing drafts. Queries
recompute positions each time; do not treat a previous position or the current
redeemer bytes as a stable final transaction property. Queries have no network
or native effects and do not change the draft.

## Balance an existing transaction

Use `Cometa.Transaction.Balancing` when you already have a transaction assembled
from fields or received as CBOR. Supply the same `Builder.Config` used for plan
building, together with resolved input snapshots:

```haskell
import qualified Cometa.Transaction.Balancing as Balancing

result <- Balancing.balance config resolvedInputs draft
```

`resolvedInputs` supplies context. Only `config.availableUtxos` authorizes
additional wallet spending; collateral-only and unrelated resolved outputs do not
become funding candidates. Existing spending inputs remain mandatory. Resolve
spending, reference and collateral inputs, including those used by nested intents.
Conflicting snapshots for one input fail before selection runs.

Every existing output remains a payment. An old change output is not identified
or removed automatically. The existing fee and `config.minimumFee` are lower
bounds. The change address controls new change; it does not replace the imported
body's network identifier. Selectors and evaluators use the same injectable
records as plan building.

The result is a new unsigned transaction. Outer key and bootstrap signatures are
removed; signed nested bodies and witnesses remain intact. Spending redeemers
follow their original inputs when new inputs change the order. Budgets, the
script-data commitment, fees and collateral are recomputed. Original snapshots
remain unchanged. Enclosing CBOR array framing can normalize, so retain the source
CBOR separately if you need it for archival interchange.

To supply a draft-dependent redeemer, identify it by its original purpose and
index. The witness must already exist in the draft:

```haskell
import qualified Cometa.Evaluation as Evaluation
import qualified Cometa.PlutusData as Data
import qualified Cometa.Transaction.Deferred as Deferred
import qualified Cometa.Transaction.Redeemer as Redeemer
import qualified Data.Map.Strict as Map

let argument =
      Deferred.redeemer (Data.Integer . toInteger)
        (Deferred.inputIndex spendingReference)
    replacements =
      Map.singleton (Evaluation.RedeemerId Redeemer.Spending 0) argument

result <- Balancing.balanceWithRedeemers config resolvedInputs replacements draft
```

The association follows that input even if its final index is no longer zero.
Callbacks can run repeatedly and report errors through the ordinary build result.
Nested redeemers belong to signed intents and are not replaced. Balancing does not
query a provider, sign, submit, or establish full ledger validity.
