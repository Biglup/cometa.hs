# Supply blockchain queries

`Cometa.Provider` is a record of ordinary `IO (Either Error a)` functions. Start
with `Provider.unavailable name networkMagic` and replace the capabilities your
application supplies. Each remaining capability returns `UnsupportedOperation`
with its operation name. Creating this record does not open a connection.

The following compiled example validates an address, queries a deterministic
backend and handles failures once. Its empty result is a successful query.

```{literalinclude} ../../examples/Providers.hs
:language: haskell
:start-at: {-# LANGUAGE
```

Use `utxosAt` for address queries, `utxosWithAsset` for asset-filtered queries, and
`resolveInputs` for output references. These return lists; no matches return an
empty list. Batch resolution omits missing references, so a caller that needs
complete resolution must check every requested reference. `utxoWithAsset` is for
an asset assumed to identify one output; ambiguous matches are errors.
`utxoWithAsset` and `resolveDatum` use `Nothing` for a missing value. A failed
request stays `Left`; never turn transport errors into missing results.

`protocolParameters` returns a complete typed snapshot, preserving availability
of optional era fields. `rewardBalance` returns lovelace as an unsigned 64-bit
integer. Queries are independent observations: this interface does not promise
that several responses describe one atomic ledger snapshot. A connected backend
must document its own freshness and consistency behavior.

`evaluateTransaction` supplies top-level execution budgets for the existing
redeemer identifiers, with additional resolved UTxOs. It neither installs the
budgets nor edits the body or witness arguments. Use the separate
[evaluation interface](evaluation-and-signing.md) when selecting a sub-transaction
level. Evaluation, balancing, signing and submission remain separate actions.

`submitTransaction` explicitly submits a signed transaction. A returned ID does
not establish confirmation. `awaitTransaction` takes a timeout in **milliseconds**;
`Right False` means the transaction was not confirmed in that interval. An
expected backend failure remains `Left`. None of the other operations submits a
transaction implicitly.

Provider implementations may throw ordinary IO exceptions; callers keep normal
Haskell exception and cancellation behavior. When supplied callbacks participate
in another Cometa operation, cancellation propagates after the operation's
required cleanup. Provider functions can also be used directly, composed with
`ExceptT`, or replaced with deterministic fakes for application tests. No custom
monad or provider class is required.
