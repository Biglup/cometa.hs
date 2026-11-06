# Inject coin selection

`Cometa.CoinSelection` lets an application supply a `Selector` record containing
one `selectCoins` function. Build a validated request, invoke `select`, and use its
complete selected inputs, remaining candidates and change outputs in the next
transaction step. `examples/CoinSelection.hs` compiles an offline workflow using
explicit demonstration parameters and deterministic resolved inputs. Its
`demonstration :: Parameters -> IO (Either Error Selection)` function accepts a
caller-supplied protocol snapshot, such as one obtained from a provider. The
runnable `main` uses the shared nonlive setup in
`test/Fixtures/ProtocolParameters.hs`.

```haskell
request <- except (Selection.mkSelectionRequest options)
result <- ExceptT (Selection.select applicationSelector request)
```

Here `except` and `ExceptT` are from `Control.Monad.Trans.Except`, and `Selection`
is a qualified import of `Cometa.CoinSelection`. The example shows one outer
failure boundary for input validation and effectful selection.

`SelectionOptions` names each input:

* `selectionPreselected` contains mandatory inputs that must remain selected.
* `selectionAvailable` contains eligible candidates. A mandatory input may also
  appear here with the same resolved output, or may be outside this list.
* `selectionTarget` is the authoritative value to fund, measured in integer
  lovelace and native-asset units. Include any externally assessed fee, deposit or
  other adjustment in this value before making the request.
* `selectionOutputHints` optionally describes payment shapes. Its sum does not
  replace the authoritative target.
* `selectionChangeAddress` receives every generated change output.
* `selectionParameters` supplies the protocol snapshot. Its Ada-per-UTxO-byte
  parameter must be available so change can be checked.

`mkSelectionRequest` rejects repeated references within either input list,
conflicting snapshots for overlapping references, negative target quantities,
quantities above `2^63 - 1`, missing minimum-Ada pricing and unsupported parameter
bounds. Validation and inspection are pure. A resolved `Utxo` is a supplied
snapshot; selection does not query whether it is still unspent.

A selector returns `Selection selected remaining change`, where `selected` is the
whole selection, including mandatory inputs. It is not just the newly chosen
candidates. `remaining` must contain exactly the available candidates that were
not selected. Each selected reference must identify the same output as one of the
request's eligible inputs, and every reference can be selected only once.

The checked runner `select` invokes the supplied function once and verifies:

```text
sum(selected input values) = authoritative target + sum(change output values)
```

This equation applies independently to Ada and every native asset. The runner
also checks mandatory inclusion, eligibility, remaining-candidate accounting,
change destinations and minimum Ada for each change output. `validateSelection`
provides the pure accounting checks separately. It does not perform the effectful
minimum-Ada check. An empty change list is valid when the selection matches the
target exactly. Ordering is retained; it does not affect these accounting laws.

The compiled example supplies a simple application policy that selects all
eligible inputs, removes the identical overlap by reference, calculates the
excess value and builds one change output. Returning an output below minimum Ada
fails through `select`; the runner does not increase amounts or select additional
inputs implicitly. A production policy can choose a smaller eligible subset or
split its change while preserving the same contract.

Expected callback failures return `Left Error` unchanged. Thrown exceptions and
asynchronous cancellation propagate normally. Use the checked runner when calling
an injected record: the raw `selectCoins` field is the application's function,
and calling it directly does not apply contextual result checks.

Selection produces a locally balanced funding choice. Transaction assembly,
execution-budget evaluation, fee calculation and final balancing continue in the
surrounding workflow. No transaction is signed or submitted by this operation.
