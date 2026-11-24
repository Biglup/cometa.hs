# Run connected examples

The named runners in `examples` build, sign and confirm complete
transaction workflows using the included Blockfrost provider. They use your
configured encrypted wallet and prompt for its password with terminal echo disabled.
Running a transaction example without arguments builds, signs, submits and waits
for confirmation. Use `--help` to print usage without opening a wallet or making requests.

For example, inspect the configured payment wallet before running the payment
flow:

```sh
cabal run cometa-send-lovelace -- --describe
cabal run cometa-send-lovelace
```

`--describe` prints public payment, selected stake and DRep identities. Relevant
governance runners also print their script identities. It does not submit a
transaction. The default invocation (or the equivalent `--submit`) runs the entire named workflow, including later dependent
stages. The [staking and governance guide](connected-governance.md) lists those
runners, their required state and their cleanup stages.

## Configure the wallet and provider

Use `COMETA_NETWORK=preprod` for these connected test-network flows. Configure
`BLOCKFROST_PROJECT_ID` and, optionally, `BLOCKFROST_URL` as described in the
[provider guide](blockfrost.md). A custom endpoint may omit the project ID when
that service does not require it.

Create an encrypted wallet file once by importing your recovery phrase. Both the
phrase and password are entered at hidden terminal prompts:

```sh
cabal run cometa-secure-key-handler -- wallet.key
export COMETA_KEY_HANDLER_FILE="$PWD/wallet.key"
```

The setup example writes encrypted storage, reopens it and derives the account
public key to verify the password. It refuses to overwrite an existing file.
Transaction examples load that file and ask for its password when deriving public
keys and signing. Passwords are not supplied through environment variables.
The recovery phrase uses the empty BIP39 passphrase; the prompted password protects
the encrypted storage. Retain your recovery phrase separately.

| Variable | Meaning |
| --- | --- |
| `COMETA_KEY_HANDLER_FILE` | Path to your encrypted serialized BIP32 software handler. |
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
Its file includes both the payment plan and the build, sign, submit and
confirmation steps. Only wallet/provider setup and address-index polling are shared:

```{literalinclude} ../../examples/SendLovelace.hs
:language: haskell
:start-at: main ::
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
deferred-redeemer recipe in the same file:

```{literalinclude} ../../examples/DeferredRedeemerSelfIndex.hs
:language: haskell
:start-at: main ::
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

`cometa-sub-transaction-batch` uses three encrypted wallets: the configured wallet
pays the batch fee, and `COMETA_BUYER_WALLET` / `COMETA_SELLER_WALLET` identify the
other two files. All three must have distinct addresses. It resolves real inputs,
builds and signs each local intent with that party's wallet, then builds, signs,
submits and confirms the enclosing batch with the batcher's wallet.

Set `COMETA_SWAP_POLICY` and `COMETA_SWAP_ASSET_NAME` to the token's policy ID and
hexadecimal asset name. `COMETA_BUYER_INPUT` must reference an output containing
exactly 100 ADA; `COMETA_SELLER_INPUT` must contain exactly 10 ADA and 5,000 units
of that token. No other assets may be present in those two outputs. The buyer
receives 50 ADA and 1,000 tokens, the seller receives 60 ADA and 4,000 tokens, and
the batcher supplies separate ordinary funds for the fee. Inputs must belong to
their respective wallets. This matches the three-party exchange in the native example.

Both batch and guarded-subtransaction examples check for protocol 12 or later
before submission. Networks running an earlier protocol cannot validate these
Dijkstra bodies. The offline tests retain synthetic swap fixtures to verify
signatures, local indexes and conservation independently of a live network.
