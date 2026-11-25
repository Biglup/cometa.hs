# Choose a provider

`Cometa.Provider.Koios`, `Cometa.Provider.Kupmios`, and `Cometa.Provider.Hydra`
implement the same scoped `Cometa.Provider` interface as Blockfrost.

```haskell
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Koios as Koios
import qualified Cometa.Provider.Kupmios as Kupmios
import qualified Cometa.Provider.Hydra as Hydra

-- Public Koios endpoint, with no API credential.
result <- Koios.withProvider (Koios.defaultConfig Koios.Preprod Nothing) $
  Provider.protocolParameters

-- Explicit local Kupo and Ogmios endpoints.
let kupmios = Kupmios.defaultConfig Kupmios.Preprod
      "http://localhost:1442" "http://localhost:1337"

-- An already-open Hydra Head.
let hydra = Hydra.defaultConfig Hydra.Preprod "http://localhost:4001"
```

Enable `OverloadedStrings` when using these endpoint literals. Supply credentials
through `mkApiKey`; validated credentials have no `Show` instance. Koios and Hydra
use bearer authentication. Kupmios has separate `kupoApiKey` and `ogmiosApiKey`
fields so credentials cannot accidentally cross endpoints. All configurations
allow request timeouts and polling intervals from 1 to 60,000 milliseconds;
the defaults are 30,000 and 1,000 milliseconds respectively. Custom endpoints
retain path prefixes and base query parameters, with operation parameters taking
precedence. Redirects, URL user information, and fragments are rejected.

`withProvider` owns the connection pools. Scope exit drains active requests;
asynchronous cancellation propagates after cleanup. Escaped operations return
`RuntimeClosed`, including operations that would otherwise need no HTTP request.

All three providers require an explicit network. They never infer it from an
endpoint URL, read credentials implicitly, or retry transaction submissions.
Protocol prices and monetary quantities retain their exact values. HTTP failures
remain errors rather than empty UTxO sets. Responses are limited to 8 MiB.

Koios uses its extended UTxO endpoints and Ogmios v6 HTTP service. Address, asset,
and input queries follow offset pages of 100, reject duplicate output identities,
and stop with an error after 10,000 pages. Separate requests are not an atomic
ledger snapshot. Kupmios combines Kupo 2.x with Ogmios v6 over HTTP; both endpoints
must use the selected network. Kupo must index the addresses and assets being
queried and retain history needed for confirmation. Large match sets exceeding
the response limit fail explicitly.

Hydra connects to an existing Conway Head over HTTP. It reads the Head's actual
protocol parameters, including its fee settings, and submits to `/transaction`
on layer 2. It does not open, commit to, close, or fan out a Head, and never uses
`/cardano-transaction` to submit to layer 1. A `202 SubmitTxSubmitted` response
acknowledges submission without claiming confirmation.

Hydra confirmation polls `/snapshot` for the transaction's CBOR in the latest
confirmed snapshot. It validates the transaction ID from those bytes. This API
cannot recover transactions that have already disappeared from the latest
snapshot's transaction list; a timeout means confirmation was not observed.
A committed L1 UTxO is not proof of an L2 transaction. Applications requiring a
complete history should consume and retain Hydra's `SnapshotConfirmed` event
stream. Snapshot confirmation is not L1 settlement.

Hydra has no remote evaluation endpoint or staking rewards. These operations
fail explicitly. Use a local script evaluator configured with the Head's ledger
parameters. Datum lookup searches inline datums in the current confirmed UTxO
set and cannot recover spent or hash-only datum bytes.
