# Run connected examples

The named runners in `examples/Connected` build, sign and confirm complete
transaction workflows using the optional Blockfrost provider. They use your
configured encrypted wallet. Running a runner without arguments prints usage
without opening the wallet or making a request.

For example, inspect the configured payment wallet before running the payment
flow:

```sh
cabal run cometa-send-lovelace -- --describe
cabal run cometa-send-lovelace -- --submit
```

`--describe` prints public payment, selected stake and DRep identities. Relevant
governance runners also print their script identities. It does not submit a
transaction. `--submit` runs the entire named workflow, including later dependent
stages. The [staking and governance guide](connected-governance.md) lists those
runners, their required state and their cleanup stages.

## Configure the wallet and provider

Use `COMETA_NETWORK=preprod` for these connected test-network flows. Configure
`BLOCKFROST_PROJECT_ID` and, optionally, `BLOCKFROST_URL` as described in the
[provider guide](blockfrost.md). A custom endpoint may omit the project ID when
that service does not require it.

| Variable | Meaning |
| --- | --- |
| `COMETA_KEY_HANDLER_FILE` | Path to your encrypted serialized BIP32 software handler. |
| `COMETA_KEY_PASSWORD` | Password used by the scoped handler. |
| `COMETA_INVALID_AFTER_SLOT` | Explicit upper validity slot on the configured network. Allow enough time for every stage's confirmation and indexing. |
| `COMETA_STAKE_INDEX` | Unhardened stake authority index; default `701`. |
| `COMETA_DREP_INDEX` | Unhardened DRep authority index; default `701`. |
| `COMETA_COLLATERAL` | Comma-separated `TXID#INDEX` references reserved as collateral; required for Plutus flows. |
| `COMETA_RESERVED_INPUTS` | Comma-separated `TXID#INDEX` references excluded from ordinary wallet selection in every stage. |

The funded payment address remains standard account zero, external key zero,
with stake key zero. Changing an authority index chooses a separate signing
credential; it does not change that wallet address. The signer includes the
payment path and both selected authority paths. No funded wallet, password or
private key is included in the example sources.

Every configured collateral reference must resolve. Collateral remains excluded
from ordinary selection independently of reserved inputs. Reserved inputs can
still be resolved explicitly, so this setting can preserve reusable reference
scripts for a later run. Use public identities and current chain queries to
choose unused stake and DRep credentials before starting a registration cycle.

## Payment and script workflows

`cometa-send-lovelace` also requires `COMETA_RECIPIENT` and `COMETA_LOVELACE`.
Its complete recipe uses the same build, sign and confirmation helper as the
other runners:

```{literalinclude} ../../examples/Connected/Transactions.hs
:language: haskell
:start-at: payment ::
:end-before: nativeScript ::
```

| Executable | Complete flow |
| --- | --- |
| `cometa-mint-burn-native-script` | Mint BerryOnyx and BerryRaspberry with metadata; burn Onyx. |
| `cometa-mint-burn-plutus-script` | Resolve `COMETA_MINT_REFERENCE`, mint both PlutusBerry assets with metadata; burn Onyx. |
| `cometa-spend-from-native-script` | Fund the source native script, confirm, then spend it with an explicit payout. |
| `cometa-spend-from-validator` | Fund the V3 validator and a reference-script output, then spend through that reference. |
| `cometa-deferred-self-index` | Fund the actual V3 self-index validator, then compute its redeemer from the balanced transaction. |
| `cometa-deferred-batch` | Fund two V3 order-pairing outputs, then settle them using their actual canonical input and payout indexes. |

The mint examples retain Raspberry, matching the C++ workflows. Their CIP-25
metadata uses the actual minting policy hash. `COMETA_MINT_REFERENCE` must carry
an executable Plutus policy suitable for the unit redeemer used by the recipe.
The validator and deferred workflows create their own funding outputs rather
than assuming that an old deployment still exists.

The validator-spending runner deliberately creates a fresh reference output
carrying the pinned native-example V3 program. The C++ runner instead resolves an
existing deployment. The new reference output holds 30 ADA under the wallet key
and can be retained for reuse or spent later. Deferred self-index and batch flows
use inline script witnesses, two-ADA locks and explicit payouts matching the C++
recipes; they do not create reference-script deployments.

The deferred self-index entrypoint uses the compiled source validator and the
shared deferred-redeemer recipe:

```{literalinclude} ../../examples/Connected/Transactions.hs
:language: haskell
:start-at: deferredSelf ::
:end-before: deferredBatch ::
```

Reference-script outputs can remain after their spending workflow finishes.
Reserve them before later independent runs if you intend to reuse them.

## Confirmation, indexing and recovery

Each stage prints and flushes its accepted transaction ID and confirmation result
before continuing. Confirmation and address indexing are separate observations:
the helper also waits until the created wallet outputs appear exactly and spent
wallet inputs disappear. Confirmation and indexing each have a bounded wait of
300 seconds. An indexing timeout stops dependent stages without resubmitting the
previous transaction. Submission is never blindly retried.

Keep the transaction journal when running a multi-stage flow. A later failure
does not undo an earlier confirmed transfer or registration. Inspect the recorded
IDs and current state before deciding how to finish a burn, spend or registration
cleanup. If a submission result is uncertain, resolve that outcome before
attempting another submission.

## Dijkstra workflows

`cometa-native-swap` implements the C++ example's offline buyer, seller and batcher
exchange with independently signed local intents. The connected
`cometa-plutus-v4-guarded-subtransaction` runner checks for protocol 12 or later
before creating any funding transaction. Protocol 11 preprod cannot validate
these Dijkstra bodies. The offline signed-batch and guarded-subtransaction tests
exercise their signatures, local indexes and budget checks; they do not establish
live-network support.
