<div align="center">
  <a href="https://cometa.dev/" target="_blank">
    <img align="center" width="300" src="assets/cometa_hs.png" alt="Cometa.hs">
  </a>
</div>

<br>

<div align="center">

![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)
[![Documentation](https://img.shields.io/readthedocs/cometahs/latest?label=docs)](https://cometahs.readthedocs.io/en/latest/)
[![Twitter Follow](https://img.shields.io/twitter/follow/BiglupLabs?style=social)](https://x.com/BiglupLabs)

</div>

<hr>

Cometa.hs is a Haskell library for building, signing and inspecting Cardano
transactions through [cardano-c](https://github.com/Biglup/cardano-c). Compose
transaction requirements as immutable values, then balance them against explicit
protocol parameters and wallet UTxOs. Expected failures use `Either Error`.
Building, signing and network requests run in `IO`.

- [Installation](#installation)
- [User guide](https://cometahs.readthedocs.io/en/latest/)
- [API reference](https://cometahs.readthedocs.io/en/latest/api-reference.html)
- [Runnable examples](examples/)
- [Contributing](docs/userguide/development.md)

The examples cover features introduced across these eras:

| Era features | Workflows |
| --- | --- |
| Shelley | Payments, stake delegation and reward withdrawals |
| Mary | Native assets, minting and burning |
| Alonzo and Babbage | Plutus spending, collateral, inline datums and reference scripts |
| Conway | DReps, voting delegation, governance proposals and votes |
| Dijkstra | Plutus V4 guards, direct deposits and independently signed subtransactions |

Use protocol parameters and ledger rules for the network you target. Dijkstra
workflows require a network that supports those features.

## Installation

Cometa.hs is not yet published on Hackage. Build the checkout with GHC, Cabal and
the cardano-c revision pinned in [`native/cardano-c.ref`](native/cardano-c.ref).
See the [installation guide](docs/userguide/installation.md) for native library
paths and runtime linking.

```sh
cabal build all
cabal run cometa-transaction-building
```

The second command builds an offline payment with synthetic inputs. To use Cometa
in an application, include the checkout in your `cabal.project` and add `cometa`
to `build-depends`. Add `cometa:blockfrost` for the optional Blockfrost backend;
the core library does not require HTTP dependencies.

## Build a payment

A plan describes what a transaction must do. `(<>)` combines requirements and
preserves output order. The builder selects inputs, calculates fees and returns
an unsigned transaction. For example, this function pays 2 ADA using supplied
wallet and protocol snapshots:

```haskell
import qualified Cometa.Address as Address
import Cometa.Error (Error)
import qualified Cometa.Protocol.Parameters as Parameters
import qualified Cometa.SlotConfig as Slots
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Word (Word64)

buildPayment :: Parameters.Parameters -> Slots.SlotConfig -> Address.Address
  -> [Utxo.Utxo] -> Address.Address -> Word64
  -> IO (Either Error Tx.Transaction)
buildPayment params slots change funds recipient expiry = runExceptT $ do
  payment <- except
    (Output.mkOutput recipient (Value.lovelace 2000000) Datum.NoDatum Nothing)
  let config = (Builder.defaultConfig params slots change)
        { Builder.availableUtxos = funds }
      plan = Plan.payTo payment <> Plan.validUntil expiry
  ExceptT (Builder.build config plan)
```

Amounts are integer lovelace: 1 ADA is 1,000,000 lovelace. `expiry` is an absolute
slot on the selected network. Use `Slots.mainnet`, `Slots.preprod` or
`Slots.preview` with matching protocol parameters, addresses and UTxOs. Validate
external addresses with `Address.fromText`. Multiple payments compose with
`Plan.payTo first <> Plan.payTo second`.

[`TransactionBuilding.hs`](examples/TransactionBuilding.hs) is a complete offline
program. [`BlockfrostPayment.hs`](examples/BlockfrostPayment.hs) fetches protocol
parameters and UTxOs, builds, signs and optionally submits the payment.

## Sign and connect to a network

The following snippets reuse the payment example's imports. A `Signer` returns
additional witnesses. Attach them explicitly; submission is a
separate provider operation:

```haskell
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import qualified Cometa.TransactionId as TxId

signAndSubmit :: Provider.Provider -> Signer.Signer -> Tx.Transaction
  -> IO (Either Error TxId.TransactionId)
signAndSubmit provider signer unsigned = runExceptT $ do
  witnesses <- ExceptT (Signer.signTransaction signer unsigned)
  signed <- except (Tx.addWitnesses witnesses unsigned)
  ExceptT (Provider.submitTransaction provider signed)
```

`Signer.ed25519`, `Signer.software` and `Signer.bip32` adapt scoped keys or software
handlers. Keep the scope open until signing completes. A custom `Signer` can
call a hardware wallet or another signing service without exporting a private
key. See [signing](docs/userguide/signing.md),
[software key handlers](docs/userguide/software-key-handlers.md) and
[wallet recovery](examples/WalletRecovery.hs).

`Provider` is a record of query, evaluation and submission functions. Use
`Cometa.Provider.Blockfrost` or supply your own backend. Submission returns an
accepted transaction ID; call `Provider.awaitTransaction` separately to wait for
confirmation. The [Blockfrost guide](docs/userguide/blockfrost.md) explains network,
endpoint and authentication configuration.

Connected examples print usage when run without arguments:

```sh
cabal run cometa-send-lovelace
```

Follow the [connected examples guide](docs/userguide/connected-examples.md) to
configure your encrypted wallet, recipient, amount and validity slot. Its
`--submit` mode runs the configured on-chain workflow.

## Native assets and metadata

Compose native-script minting with a token output. This function takes a
validated policy script and asset name, hashes the actual script for its policy
ID, and mints one token:

```haskell
import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import qualified Cometa.PolicyId as PolicyId
import qualified Cometa.Script as Script
import qualified Cometa.Script.Native as NativeScript

mintToken :: Address.Address -> NativeScript.NativeScript -> AssetName.AssetName
  -> IO (Either Error Plan.Plan)
mintToken recipient policy name = runExceptT $ do
  let script = Script.Native policy
  digest <- ExceptT (Script.hash script)
  let asset = AssetId.Native (PolicyId.fromScriptHash digest) name
      value = Value.lovelace 2000000 <> Value.fromList [(asset, 1)]
  output <- except (Output.mkOutput recipient value Datum.NoDatum Nothing)
  pure (Plan.attachScript script <> Plan.mint asset 1 <> Plan.payTo output)
```

Pass the result to `Builder.build` with your configuration. Satisfy the native
policy's signatures and validity interval, and fund the minimum ADA required by
the output. Negative mint quantities burn tokens. `Plan.metadata` adds metadata
under an integer label; the [mint/burn recipe](examples/Connected/Transactions.hs)
includes CIP-25 metadata under label 721 and both native and Plutus policies.
See [assets and values](docs/userguide/assets-values.md) for validated asset names,
policy IDs and multi-asset arithmetic.

## Plutus contracts and deferred redeemers

Attach a native or Plutus script with `Plan.attachScript`, or use an existing
reference-script UTxO through `Plan.referenceInput`. `Output.mkOutput` accepts a
datum and optional reference script; `Plan.spendWith` supplies a spending
redeemer and optional datum witness. Plutus minting, withdrawals, certificates,
votes and governance proposals have corresponding redeemer operations.

Builders evaluate scripts locally by default. Supply current protocol parameters,
cost models, resolved inputs, scripts, datums and suitable collateral through the
builder configuration. An application can inject its own evaluator or coin
selector. See [script evaluation](docs/userguide/evaluation-and-signing.md) and
[transaction building](docs/userguide/transaction-building.md).

When a redeemer depends on final input or output ordering, use the deferred
operations such as `Plan.spendWithDeferredRedeemer`. The callback receives the
balanced draft and may run repeatedly; keep its result deterministic. The
[deferred redeemer example](examples/DeferredRedeemers.hs) and
[connected self-index and batch recipes](examples/Connected/Transactions.hs)
show how to derive actual indexes instead of assuming them.

## Staking and Conway governance

Staking certificates, reward withdrawals, DRep registration, voting delegation,
proposals and votes compose with payments in the same plan. For example,
delegate an existing stake credential's voting power to abstention and cast a
DRep vote on a supplied governance action:

```haskell
import qualified Cometa.Certificate as Certificate
import qualified Cometa.Credential as Credential
import qualified Cometa.Governance.ActionId as ActionId
import qualified Cometa.Governance.DRep as DRep
import qualified Cometa.Governance.Voting as Voting

abstainDelegation :: Credential.Credential Credential.Stake -> Plan.Plan
abstainDelegation stake =
  Plan.certificate (Certificate.VoteDelegation stake DRep.AlwaysAbstain)

voteYes :: Credential.Credential Credential.DRep -> ActionId.ActionId -> Plan.Plan
voteYes drep action =
  Plan.vote (Voting.DRepVoter drep) action
    (Voting.VotingProcedure Voting.Yes Nothing)
```

Registration deposits and deregistration refunds are explicit certificate values.
`Plan.withdraw` withdraws staking rewards, `Plan.donate` donates to the treasury,
and `Plan.propose` adds a governance action with a return account and metadata
anchor. Use `Plan.proposeWithRedeemer` or `Plan.proposeWithDeferredRedeemer` for a
custom guardrails argument. `Plan.currentTreasuryValue` declares a treasury
balance without transferring funds. Proposal deposits come from the protocol
snapshot. Ledger registration,
reward balances, action eligibility and required signing authorities must match
the target network's state.

The [staking and governance guide](docs/userguide/connected-governance.md) links
complete key- and script-authorized registration, delegation, reward withdrawal,
DRep, proposal and vote workflows, including cleanup stages.

## Dijkstra guards, account deposits and batches

Dijkstra features require a network that has activated the corresponding ledger
rules. An offline build does not establish network acceptance. The connected
Plutus V4 example checks for protocol 12 or later before funding its workflow.

Guards authorize a transaction with a key or script. Direct deposits transfer
lovelace to reward accounts without creating a UTxO; balance constraints express
requirements on those accounts:

```haskell
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Transaction.Fields as Fields

guardedDeposit :: Credential.Credential Credential.Guard
  -> Reward.RewardAddress -> Plan.Plan
guardedDeposit guard account =
  Plan.requireGuard guard
    <> Plan.directDeposit account 1000000
    <> Plan.startingAccountBalance account (Fields.ExactBalance 2000000)
    <> Plan.accountBalance account (Fields.BalanceRange (Just 3000000) Nothing)
```

For a Plutus guard, use `Plan.guardWithRedeemer` and attach its script. Plutus V4
guards can inspect the enclosing batch. See the full
[account and governance example](examples/DijkstraBuilding.hs).

Fee-free subtransactions can be built and signed independently, then attached to
an enclosing transaction with their resolved inputs. The enclosing builder funds
net deficits, balances change and supplies fees and collateral:

```haskell
import qualified Cometa.Crypto.Ed25519.SigningKey as Key
import qualified Cometa.SubTransaction.Builder as SubBuilder
import qualified Cometa.SubTransaction.Plan as SubPlan
import qualified Cometa.Transaction.Signing as Signing

buildSignedBatch :: Key.SigningKey -> SubBuilder.Config -> Builder.Config
  -> Utxo.Utxo -> Output.Output -> IO (Either Error Tx.Transaction)
buildSignedBatch key localConfig outerConfig funding payment = runExceptT $ do
  let intent = SubPlan.spend funding <> SubPlan.payTo payment
  local <- ExceptT (SubBuilder.build localConfig intent)
  signedIntent <- ExceptT (Signing.signSubTransaction key local)
  let plan = Plan.attachSubTransaction signedIntent (SubPlan.resolvedInputs intent)
  batch <- ExceptT (Builder.build outerConfig plan)
  ExceptT (Signing.sign key batch)
```

Use matching Dijkstra protocol parameters and slot schedules in both
configurations. `outerConfig` supplies an independent fee-payer UTxO through
`Builder.availableUtxos`; inputs spent at different levels must be disjoint.
This example signs both levels with one open key. Independent parties can sign
their own intents before a batcher attaches them. Attaching an intent preserves
its exact bytes and signatures. Complete workflows:

- [Build, sign and balance a batch](examples/SubTransactionBuilding.hs)
- [Buyer, seller and batcher swap](examples/NativeSwap.hs)
- [Plutus V4 guarded subtransaction](examples/Connected/PlutusV4GuardedSubTransaction.hs)
- [Guard and batch contracts](docs/userguide/dijkstra-building.md)

## More examples

| Task | Example |
| --- | --- |
| Addresses and credentials | [Addresses.hs](examples/Addresses.hs) |
| CBOR and exact transaction encodings | [Cbor.hs](examples/Cbor.hs), [Transactions.hs](examples/Transactions.hs) |
| Plutus data and script parameters | [PlutusData.hs](examples/PlutusData.hs), [Scripts.hs](examples/Scripts.hs) |
| CIP-8 message signing | [MessageSigning.hs](examples/MessageSigning.hs) |
| Transaction JSON inspection | [TransactionInspection.hs](examples/TransactionInspection.hs) |
| Custom providers, evaluators and selection | [Providers.hs](examples/Providers.hs), [Evaluation.hs](examples/Evaluation.hs), [CoinSelection.hs](examples/CoinSelection.hs) |

Offline examples use synthetic inputs or public fixtures and do not submit
transactions. Connected runners document their required network state and take
an explicit `--submit` argument. Build and test the checkout with:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock all
```

## License

Cometa.hs is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
