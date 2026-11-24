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

## Build a payment

Validate an output, compose a plan, and pass it to the builder:

```haskell
import Cometa.Address (Address)
import Cometa.Error (Error)
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Datum as Datum
import qualified Cometa.Transaction.Output as Output
import qualified Cometa.Transaction.Plan as Plan
import qualified Cometa.Value as Value

buildPayment :: Builder.Config -> Address -> IO (Either Error Tx.Transaction)
buildPayment config recipient =
  case Output.mkOutput recipient (Value.lovelace 2000000) Datum.NoDatum Nothing of
    Left failure -> pure (Left failure)
    Right output -> Builder.build config (Plan.payTo output)
```

Configure the builder with current protocol parameters, matching network slots,
wallet UTxOs and a change address. Amounts use integer lovelace: one ADA is
1,000,000 lovelace. Plans compose with `(<>)` for multiple outputs, minting,
certificates, withdrawals and governance actions. Signing and submission are
separate operations.

## Examples

The [example directory](examples/README.md) follows the Cometa C++ workflows,
with CIP-8 data signing also shared by the Python and TypeScript bindings. It
covers key recovery and storage, payments, native and Plutus scripts, staking,
governance, deferred redeemers and subtransaction batches.

```sh
cabal run cometa-send-lovelace
```

Connected examples print usage by default. Configure them using the
[connected workflow guide](docs/userguide/connected-examples.md); `--submit`
executes the named transaction sequence. Dijkstra examples require a network
supporting those features.

## Contributing

See [development](docs/userguide/development.md) and
[coding conventions](CODING_CONVENTIONS.md). Run `cabal test all
--test-show-details=direct` and the configured formatter and linter before
submitting changes.

Licensed under [Apache-2.0](LICENSE). The bundled native dependency includes
third-party components with their own [notices](native/NOTICE).
