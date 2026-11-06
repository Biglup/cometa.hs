# Compute redeemers from the balanced transaction

A script argument can depend on selected input positions, change outputs, or the
fee. Supply a `Plan.DeferredRedeemer` when these values become available only
through balancing:

```haskell
argument :: Plan.DeferredRedeemer
argument draft selected =
  Right (Data.fromData (Data.Integer (toInteger (length selected))))

plan = Plan.spendWithDeferredRedeemer scriptInput argument Nothing
    <> Plan.attachScript validator
    <> Plan.payTo payment
```

The callback receives an immutable transaction draft and its fully resolved
selected spending inputs in canonical order. Reference and collateral inputs are
separate body fields and are not included in this list. The draft includes change
outputs and the current balancing fee. The callback may run again as balancing
converges; compute the result solely from these values and immutable captured
values. A callback must not depend on mutable state, randomness, or external
queries. Avoid depending on another deferred argument, since resolution updates
arguments in registration order.

Use `Cometa.Transaction.Indices` to locate objects in the current draft:
`findInput` and `findReferenceInput` use canonical hash/index order,
`findMintPolicy` uses policy-hash order, and `findOutput address minimumLovelace`
returns the first qualifying output in body order. Each returns `Maybe Word64`;
`Nothing` means there is no match. Compute these positions inside the callback,
since balancing can change the inputs and outputs.

Return `Left Error` when the draft cannot support your argument. `Builder.build`
returns that error at the same boundary as validation and evaluation errors.
Thrown exceptions, including exceptions delayed inside an encoded argument,
propagate after the operation unwinds. Ordinary asynchronous cancellation also
unwinds the build before returning control.

For minting, declare all assets under one policy together. One policy has one
redeemer, irrespective of the number of asset names:

```haskell
Plan.mintWithDeferredRedeemer policy [(firstName, 2), (secondName, 3)] argument
```

Repeated asset names have their signed quantities added. Zero totals are omitted;
an empty or completely cancelled group never invokes its callback. Register a
policy once when using a deferred argument. Separate declarations for that
policy, or a mixture of immediate and deferred arguments for it, fail during
build validation. Spending inputs and reward accounts likewise require one
registration when their argument is deferred. Certificate arguments use
`Plan.certificateWithDeferredRedeemer`; reward arguments use
`Plan.withdrawWithDeferredRedeemer`, including zero withdrawals used only for
script authorization.

`examples/DeferredRedeemers.hs` demonstrates an offline native mint, a callback
that reads input count, output count and fee, and one error boundary. The small
script always succeeds; application validators must check the argument's meaning.
The example uses synthetic wallet inputs and performs no chain queries or
submission.

```{literalinclude} ../../examples/DeferredRedeemers.hs
:language: haskell
:start-at: module Main
```
