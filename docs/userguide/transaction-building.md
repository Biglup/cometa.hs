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
import Cometa.Address (Address)
import Cometa.Error (Error)
import qualified Cometa.Transaction as Tx
import Cometa.Transaction.Output (Output)
import Data.Word (Word64)
import qualified Cometa.Provider as Provider
import qualified Cometa.SlotConfig as Slot
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Plan as Plan
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)

buildPayment :: Provider.Provider -> Address -> Output -> Word64
  -> IO (Either Error Tx.Transaction)
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
signatures; use the [signing workflow](api-reference.md) and submit it
explicitly through your provider.

For custom policies set `Builder.selector` to `Just selector` or
`Builder.evaluator` to `Just evaluator`. These are ordinary records of functions;
see [selection](api-reference.md) and [evaluation](api-reference.md).
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

See the {download}`payment example <../../examples/SendLovelace.hs>` for a complete connected workflow.
