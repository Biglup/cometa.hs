# Run the connected Blockfrost examples

The connected examples use the separate `cometa:blockfrost` component. They read
configuration from the environment and do no network work when invoked without
an action argument. The following commands are intended for your own configured
wallet; ordinary tests use fixtures instead of credentials or funded inputs.

Set `COMETA_NETWORK` to `mainnet`, `preprod` or `preview`. Set
`BLOCKFROST_PROJECT_ID` to a project belonging to that network. The project ID is
sent in the HTTP authentication header and is never printed by these examples.
Keep credentials out of source files and shell history. For example, Bash can
read an existing project ID without echoing it:

```sh
export COMETA_NETWORK=preprod
read -rs BLOCKFROST_PROJECT_ID
export BLOCKFROST_PROJECT_ID
```

## Query an address

Set `COMETA_ADDRESS` to a validated address, then run:

```sh
cabal run cometa-blockfrost-queries -- --query
```

The example obtains protocol parameters and unspent outputs and prints the
protocol version, output count and lovelace balance. Set `COMETA_REWARD_ADDRESS`
optionally to query and print that account's available rewards. It creates no
transaction.
The observations are separate HTTP requests, not an atomic ledger snapshot.

```{literalinclude} ../../examples/BlockfrostQueries.hs
:language: haskell
:start-at: query ::
```

## Build or submit a payment

The payment example loads an existing encrypted software key handler from
`COMETA_KEY_HANDLER_FILE` and requests its password from `COMETA_KEY_PASSWORD`.
The key remains in its scoped handler while deriving the address and signing.
The program never prints the handler bytes, password, private key or project ID.
The password variable is still ordinary process environment data; use your
application's password prompt or secret store when adapting this recipe.

For a BIP32 handler it uses account `1852'/1815'/0'`, external payment index zero
and stake index zero. An Ed25519 handler uses an enterprise address. Obtain funds
for the resulting address through your own wallet workflow; the program never
imports demonstration keys as live wallet defaults.

Set the following values explicitly:

| Variable | Meaning |
| --- | --- |
| `COMETA_KEY_HANDLER_FILE` | Path to encrypted bytes produced by the software key-handler API |
| `COMETA_KEY_PASSWORD` | Password for that encrypted handler |
| `COMETA_RECIPIENT` | Recipient address on the selected network |
| `COMETA_LOVELACE` | Nonnegative decimal payment amount, within unsigned 64-bit |
| `COMETA_INVALID_AFTER_SLOT` | Exclusive validity upper bound as an absolute slot for the selected network |

The examples require a slot instead of guessing chain time from a local clock.
The provider record has no current-tip or registration-state query. Choose a
valid future bound from your application's chain-state source. Network schedules
convert validity slots using the corresponding `SlotConfig`.

Build and sign without submitting:

```sh
cabal run cometa-blockfrost-payment -- --build
```

This queries current parameters and wallet UTxOs, balances the payment, signs it
and prints its body identifier. `--submit` explicitly performs that same workflow,
submits the exact signed bytes once and waits up to 240,000 milliseconds for
confirmation:

```sh
cabal run cometa-blockfrost-payment -- --submit
```

A confirmation timeout means the accepted transaction has not been confirmed within
that wait. A timeout during submission leaves acceptance uncertain. Do not blindly retry a
submission whose acceptance is uncertain. The example does not automatically
repeat a submission.

```{literalinclude} ../../examples/BlockfrostPayment.hs
:language: haskell
:start-at: payment ::
:end-before: unsigned ::
```

## Script, staking and governance workflows

The [native workflow recipes](native-workflows.md) perform multi-stage
query → build → sign → submit → confirm → query flows through the same provider
record. Supply appropriate authority paths, complete collateral references,
registration/deposit state and proposal identifiers for the chosen network.
Script and governance features must also be available at its protocol version;
a fixture running Dijkstra code does not establish deployment on a public network.
