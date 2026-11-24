<div align="center">

<img src="assets/cometa_hs.png" alt="Cometa.hs" width="320" />

[API documentation](https://hackage.haskell.org/package/cometa-0.1.0.0/candidate/docs/index.html) · [Examples](examples/README.md) · [User guide](https://cometahs.readthedocs.io/en/latest/)

</div>

# Cometa.hs

Haskell bindings to [cardano-c](https://github.com/Biglup/cardano-c) for building,
signing and inspecting Cardano transactions. Compose immutable transaction plans,
work with typed addresses, assets and credentials, and use the included Blockfrost
provider or supply your own backend.

Pure validation returns `Either Error`; native operations and network requests
return `IO (Either Error a)`. Private keys stay inside explicit resource scopes.

## Build

Version 0.1.0.0 is available as a [Hackage candidate](https://hackage.haskell.org/package/cometa-0.1.0.0/candidate).
It is not yet in the main package index. To build this checkout, use GHC 9.6.7
or 9.10.3, Cabal and a C toolchain. Prepare the bundled native sources from the
revision in [`native/cardano-c.ref`](native/cardano-c.ref):

```sh
python3 tools/package-native.py /path/to/pinned/cardano-c
cabal build all
cabal run cometa-bip39
```

See [installation](docs/userguide/installation.md) for platform requirements and
linking an installed native library. Applications depend on `cometa`; Blockfrost
is part of the same library.

## Build, sign and submit a payment

Validate an output, build a transaction, sign it with the wallet and submit it:

```haskell
import Cometa.Address (Address)
import Cometa.Error (Error)
import qualified Cometa.Provider as Provider
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Value as Value
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)

sendPayment :: Builder.Config -> Signer.Signer -> Provider.Provider -> Address -> IO (Either Error Bool)
sendPayment config signer provider recipient = runExceptT $ do
  output <- except (Output.mkOutput recipient (Value.lovelace 2000000) Datum.NoDatum Nothing)
  unsigned <- ExceptT (Builder.build config (Plan.payTo output))
  witnesses <- ExceptT (Signer.signTransaction signer unsigned)
  signed <- except (Tx.addWitnesses witnesses unsigned)
  txId <- ExceptT (Provider.submitTransaction provider signed)
  ExceptT (Provider.awaitTransaction provider txId 300000)
```

Configure the builder with current protocol parameters, matching network slots,
wallet UTxOs and a change address. Amounts use integer lovelace: one ADA is
1,000,000 lovelace. Plans compose with `(<>)` for multiple outputs, minting,
certificates, withdrawals and governance actions. The signer comes from the scoped encrypted wallet; the full
[payment example](examples/SendLovelace.hs) loads it and prompts for its password.

## Run the examples

Start by importing a recovery phrase into an encrypted wallet file. The terminal
hides both the recovery phrase and password as you type:

```sh
cabal run cometa-secure-key-handler -- wallet.key
export COMETA_KEY_HANDLER_FILE="$PWD/wallet.key"
export COMETA_NETWORK=preprod
export BLOCKFROST_PROJECT_ID="your-preprod-project-id"
```

Set a current `COMETA_INVALID_AFTER_SLOT`, `COMETA_RECIPIENT` and
`COMETA_LOVELACE` using the [connected examples guide](docs/userguide/connected-examples.md).
Then run:

```sh
cabal run cometa-send-lovelace -- --describe
cabal run cometa-send-lovelace
```

Each transaction example shows its plan, build, sign, submit and confirmation
steps in one file. Shared helpers handle wallet/provider setup. The examples
prompt for the encrypted wallet password and submit on chain. Multi-stage examples confirm each
transaction before continuing. `--help` prints usage without network requests.

| Example | What it demonstrates |
| --- | --- |
| [BIP39](examples/Bip39.hs) | Recover keys and derive an address from a mnemonic. |
| [Encrypted wallet](examples/SecureKeyHandler.hs) | Import a recovery phrase, encrypt, save and reopen a wallet. |
| [Provider](examples/Provider.hs) | Query protocol parameters, UTxOs and rewards. |
| [Send lovelace](examples/SendLovelace.hs) | Build, sign, submit and confirm a payment. |
| [Native mint/burn](examples/MintBurnNativeScript.hs) | Mint tokens with CIP-25 metadata, then burn tokens. |
| [Plutus mint/burn](examples/MintBurnPlutusScript.hs) | Mint and burn through a reference policy. |
| [Native script spend](examples/SpendFromNativeScript.hs) | Fund a script address, then spend its output. |
| [Validator spend](examples/SpendFromValidator.hs) | Lock funds and spend with a Plutus validator. |
| [Deferred self index](examples/DeferredRedeemerSelfIndex.hs) | Compute a redeemer after input ordering is known. |
| [Deferred batch](examples/DeferredRedeemerBatch.hs) | Fund and settle two script orders. |
| [Stake key](examples/RewardAccountPubkey.hs) / [stake script](examples/RewardAccountScript.hs) | Register, delegate, withdraw and deregister. |
| [DRep key](examples/DRepPubkey.hs) / [DRep script](examples/DRepScript.hs) | Register a representative, delegate and clean up. |
| [Key vote](examples/VoteForProposalPubkey.hs) / [script vote](examples/VoteForProposalScript.hs) | Register, vote on a proposal and deregister. |
| [Treasury donation](examples/DonateToTreasury.hs) | Donate ADA to the treasury. |
| [Treasury withdrawal](examples/ProposeTreasuryWithdrawal.hs) | Submit a treasury withdrawal proposal. |
| [Deferred withdrawal](examples/DeferredWithdrawZero.hs) | Forward input indexes through a withdrawal redeemer. |
| [Subtransaction batch](examples/SubTransactionBatch.hs) | Three encrypted wallets sign and settle a buyer/seller exchange. |
| [Guarded subtransaction](examples/PlutusV4GuardedSubTransaction.hs) | Sign a guarded V4 intent and submit its enclosing batch. |
| [Sign data](examples/SignData.hs) | Produce a CIP-8 message signature offline. |

See the [example index](examples/README.md) for Cabal commands and
[governance setup](docs/userguide/connected-governance.md) for required chain state.
The batch and V4 examples require a network supporting protocol 12 or later.
BIP39 and data-signing demos use public demonstration keys; never fund them.

## Transaction plan examples

Plans compose with `(<>)`. These fragments use validated addresses, outputs,
assets, scripts and credentials; the linked executable examples include their
construction and the complete wallet/provider flow. Pass the resulting plan to
`Builder.build`, sign with `Signer.signTransaction`, attach the witnesses with
`Tx.addWitnesses`, then call `Provider.submitTransaction` and
`Provider.awaitTransaction`.

### Multiple outputs

```haskell
Plan.payTo firstOutput <> Plan.payTo secondOutput
```

### Mint and burn tokens

```haskell
Plan.attachScript nativePolicy <> Plan.mint asset 100
Plan.attachScript nativePolicy <> Plan.mint asset (-50)
```

Use a Plutus redeemer when the policy requires one:

```haskell
Plan.attachScript plutusPolicy <> Plan.mintWithRedeemer asset 100 redeemer
```

### Spend a script output

```haskell
Plan.attachScript validator
  <> Plan.spendWith lockedOutput (Just redeemer) Nothing
  <> Plan.payTo payout
```

### Withdraw rewards and vote

```haskell
Plan.withdraw rewardAccount rewardLovelace
Plan.vote voter actionId votingProcedure
```

### Donate to the treasury

```haskell
Plan.donate 2000000
```

## Contributing

See [development](docs/userguide/development.md) and
[coding conventions](CODING_CONVENTIONS.md). Run `cabal test all
--test-show-details=direct` and the configured formatter and linter before
submitting changes.

Licensed under [Apache-2.0](LICENSE). The bundled native dependency includes
third-party components with their own [notices](native/NOTICE).
