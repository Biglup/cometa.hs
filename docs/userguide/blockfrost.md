# Query Cardano through Blockfrost

The optional `cometa:blockfrost` library supplies `Cometa.Provider.Blockfrost`.
HTTP and TLS dependencies stay in that component. The backend implements the
ordinary `Cometa.Provider` record, so query results can feed the existing
transaction builder and signer workflows.

Choose `Mainnet`, `Preprod`, or `Preview` for the chain's network magic.
`Blockfrost.defaultConfig network Nothing` uses its official endpoint without a
project header. For authenticated services, validate the project identifier with
`Blockfrost.mkProjectId` and pass `Just project` instead.

Set `endpoint` to use another Blockfrost-compatible service, proxy or local server.
It accepts an absolute HTTP or HTTPS URL, including a base path and query parameters.
The selected network remains independent of the URL. With `OverloadedStrings`:

```haskell
let config =
      (Blockfrost.defaultConfig Blockfrost.Preprod Nothing)
        { Blockfrost.endpoint = "http://localhost:3000/api/v0" }
```

The defaults are a 30-second request timeout and a one-second confirmation poll
interval; both can be set between 1 and 60000 milliseconds. Project identifiers
and complete configuration values have no `Show` instance. Without a project ID,
no `project_id` header is sent. Base URL query parameters are retained; operation
parameters such as pagination take precedence over the same names in the URL.

```haskell
result <- Blockfrost.withProvider config $ \provider ->
  Provider.utxosAt provider address
```

For a workflow with several operations, run `ExceptT` inside `withProvider` and
use `ExceptT (Provider.operation provider ...)` for each step. Expected errors
return through the same `Either Error` boundary. The scope shares its transport,
waits for active requests during cleanup, and rejects escaped provider operations
with `RuntimeClosed`. Cancellation propagates after request cleanup. Configuration
and project identifiers are not read implicitly from the environment or files.

Address and asset queries fetch ascending pages of 100 results. A query permits
at most 10000 pages and rejects repeated input identities rather than silently
returning duplicate or conflicting snapshots. Results retain response order.
Reference scripts are fetched as needed, checked against their advertised hashes,
and reused within the query. Inline datums with an advertised datum hash are also
checked before returning an output. Datum lookup retains exact returned CBOR and
verifies its requested hash.

`Provider.resolveInputs` returns distinct requested references in first-request
order and omits missing inputs. A historical transaction output does not establish
that it remains unspent: the backend obtains its address and checks the current
address UTxO list. A supplied `consumed_by_tx` also excludes a spent output. These
requests are separate observations, so chain updates can race the query; callers
must obtain a fresh snapshot when their workflow requires one.

A missing address yields `[]`, a missing datum or NFT yields `Nothing`, and an
unknown reward account has balance zero. NFT lookup requires a native asset and
rejects multiple matching outputs or a quantity other than one. Endpoint failures,
malformed responses and ambiguous results remain errors. HTTP status is retained
in `ProviderHttpError`; transport errors use a stable sanitized reason. Server
bodies, project identifiers and raw HTTP request exceptions are not included in
error diagnostics. There are no automatic retries, including for rate limits.

Submission sends the exact transaction CBOR once and checks the returned identifier
against the locally computed transaction ID. A failed response can leave submission
status uncertain, so callers must determine its status before deciding to retry.
Confirmation polls the on-chain transaction endpoint until its identifier matches
or the supplied millisecond timeout expires. Zero timeout returns `False` without
an HTTP request. Confirmation establishes block inclusion, not finality.

Remote evaluation uses the documented Blockfrost Ogmios v5 request dialect,
including all supplied additional UTxOs. It supports Plutus V1/V2 and spending,
minting, certificate and withdrawal redeemer purposes. Unsupported scripts,
governance or Dijkstra body features, subtransactions, and unrepresentable
additional inputs return `UnsupportedOperation` before the request. Evaluation
budgets must cover exactly the existing redeemer identities; partial successes
are rejected. `Cometa.Evaluation.Native` remains available for the newer features
supported by the pinned local native VM.

Protocol snapshots decode the documented fields exactly, including decimal
execution prices without floating-point rounding. Optional fields that Blockfrost
does not supply remain `Nothing`; the backend does not invent Dijkstra, Leios or
Peras parameters. The available online schema therefore differs from the full
offline binding's capabilities.

See [the Blockfrost examples](blockfrost-examples.md) for command-line workflows
with explicit query, build and submission choices, and
[the native workflows](native-workflows.md) for deterministic offline examples.
