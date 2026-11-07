# Run complete transaction workflows

The example helpers in `examples/Workflows/Native.hs` port the native caller flow:
query current parameters and wallet outputs, build from typed plans, sign through
a scoped signer, submit exact bytes, confirm, then query again before a dependent
stage. These helpers are example source, separate from the installed public API.

Each function named `run…` submits through the supplied provider. Choose that
provider and authorize the complete flow explicitly. Ordinary tests supply an
in-memory provider; the [connected payment example](blockfrost-examples.md)
requires a separate `--submit` argument. No test needs project credentials or
funded keys.

A context supplies the wallet address, signer, address network, slot schedule,
exclusive validity slot, reserved collateral references, additional witness count
and confirmation timeout. Collateral inputs must resolve exactly once and are
excluded from ordinary selection at every stage. Signer scopes must enclose the
complete workflow, including every later stage that signs again.

```{literalinclude} ../../examples/Workflows/Native.hs
:language: haskell
:start-at: runStage ::
:end-before: runPayment ::
```

An accepted identifier must match the signed body's identifier. If confirmation
returns false or a request fails, the helper stops before any dependent stage.
It queries fresh wallet outputs and parameters for every transaction rather than
reusing a pre-submission snapshot.

## Choose a recipe

| Recipe | Stages and explicit application inputs |
| --- | --- |
| `runPayment` | Pay a validated address and lovelace amount |
| `runMintBurn` | Mint under a native or Plutus policy, confirm, then burn; optionally supply a resolved reference script |
| `runLockSpend` | Fund a script output, confirm, then spend its exact reference; Plutus spending resolves a separately funded reference script |
| `runDeferredSelf` | Fund an indexed validator, then compute its actual canonical input index from the balanced draft |
| `runDeferredBatch` | Fund two indexed orders, then pair each canonical input with its payout-output position |
| `runRewardCycle` | Register and delegate an explicitly unregistered reward credential, query rewards, withdraw and deregister using the supplied refund |
| `runWithdrawZero` | Register a script reward credential, then withdraw zero with a late canonical-input list and deregister |
| `runDRepCycle` | Register a DRep, register/delegate a stake credential to it, withdraw/deregister stake, then deregister the DRep |
| `runVoteCycle` | Register a DRep, vote on the supplied existing action identifier, then deregister |
| `runTreasuryWithdrawal` / `runDonation` | Propose a guarded treasury withdrawal or donate lovelace |
| `runSignedBatch` | Assemble already signed intents and their resolved inputs under a parent plan |
| `runGuardedSub` | Fund a V4 validator, build and sign a local intent with a separate V4 guard, then build its enclosing batch |

Registration status, pools, DRep deposits/refunds and governance action identifiers
are application inputs. The provider's reward-balance query does not establish
registration state. Do not register an already registered credential or infer a
historic refund from the latest protocol deposit. The native examples also assume
a prepared account/proposal state; these recipes make those assumptions explicit.

The deferred examples use the actual compiled native Aiken self-index,
order-pairing and withdraw-zero programs. Their validators inspect the supplied
indices; replacing them with an always-succeeding fixture would not verify those
workflows. Imported compiled bytes and source notices are in
`examples/Workflows/NativeScripts.hs`.

## Independent buyer and seller intents

`cometa-native-swap` ports the native offline token trade. A buyer offers
50,000,000 lovelace for 1,000 tokens; a seller offers those tokens for the opposite
coin amount. Each party signs its own local intent and requires the batcher's
top-level guard. A third key supplies the fee, combines the signed intents and
signs the enclosing transaction. The example checks complete value conservation
and that both signed intent encodings are carried unchanged.

```sh
cabal run cometa-native-swap
```

The keys and inputs in this example are public demonstration material and
synthetic UTxOs. It performs no network calls and must never be funded.

## What the offline checks establish

The native-workflow tests perform actual native balancing and script execution,
verify every outer and nested Ed25519 witness against its own exact body hash,
materialize typed outputs and verify complete value conservation. Their provider tracks spent references and new outputs in memory,
then confirms known submitted identifiers. It is a deterministic stage fixture,
not a consensus ledger or a Blockfrost server. It does not establish registration
eligibility, epoch rewards, public-network acceptance or finality. HTTP fixture
coverage and any explicitly authorized live observations are separate evidence.

Run the normal suite from the checkout:

```sh
cabal test cometa-test --test-show-details=direct
```
