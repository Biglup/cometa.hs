# Assets and values

Use `Cometa.AssetId` to identify Ada or a native token, and `Cometa.Value` to
assemble and inspect their quantities. Asset identities and values are immutable;
construction, arithmetic, and inspection are pure.

## Assemble a token payment

A native asset is identified by its 28-byte policy ID and asset name of up to
32 bytes. Validate these inputs once, then use `AssetId.Native policy name`
wherever the asset is needed. `AssetId.Ada` identifies Ada independently of any
policy or name. An empty name under a policy still identifies a native token.

The following example imports a policy and token name, combines Ada and token
quantities, and computes the token balance after a payment. It uses demonstration
values and makes no network requests.

```{literalinclude} ../../examples/AssetsValues.hs
:language: haskell
:start-at: "{-# LANGUAGE OverloadedStrings #-}"
```

Run it with:

```sh
cabal run cometa-assets-values
```

Input validation has one `Either Error` boundary. Once the policy and name are
validated, `Value.singleton`, `Value.fromList`, and arithmetic compose them
without further validation branches.

## Import asset identities

`AssetName.fromBytes` accepts any byte sequence from zero through 32 bytes,
including NUL and invalid UTF-8. `AssetName.empty` is the empty name.
`AssetName.toBytes` preserves the exact bytes.

Use `AssetName.fromHex` and `AssetName.toHex` for lossless hexadecimal interchange.
`AssetName.fromText` encodes text as UTF-8 and checks the resulting byte length;
32 characters may require more than 32 bytes. No Unicode normalization is applied.
`AssetName.toText` returns `Nothing`
when the bytes are not valid UTF-8. Binary names are valid assets and do not need
a text interpretation.

`PolicyId.fromBytes` requires exactly 28 bytes. `PolicyId.fromHex` imports its
hexadecimal representation. Use `PolicyId.toBytes` and `PolicyId.toHex` to export
it. A policy ID is a script hash: `PolicyId.fromScriptHash` and
`PolicyId.toScriptHash` convert validated values directly. Importing a policy ID
does not compute a script hash or establish the right to mint tokens.

## Add quantities and inspect balances

Quantities are arbitrary-precision `Integer` values. Ada quantities are measured
in lovelace: one Ada is 1,000,000 lovelace. Native-token quantities are integer
units of that asset; any display decimals come from the application's metadata.

`Value.lovelace amount` constructs an Ada-only value. `Value.singleton asset amount`
constructs a value for one asset. Use `(<>)` to add values and `mempty` for zero;
`foldMap` and `mconcat` combine lists of contributions. `Value.fromList` adds
quantities for repeated asset IDs. Every constructor and arithmetic operation
removes zero entries, including entries that cancel each other.

`Value.quantity asset value` returns zero when the asset is absent.
`Value.toList` returns each nonzero asset once, ordered with Ada first, then native
assets by policy bytes and name bytes. Input order is not retained.
`Value.isZero` checks whether every quantity is zero.

`Value.difference available required` subtracts the second value from the first.
`Value.negate` changes every quantity's sign, and `Value.scale factor value`
multiplies every quantity by an integer. Negative results are retained: they
represent deficits, burns, or balance changes. Arithmetic does not clamp them.

`Value.isNonNegative` checks that every asset quantity is at least zero. This
check alone does not establish that a value can be used in a transaction output:
transaction construction also needs the applicable quantity bounds, minimum Ada,
and other ledger constraints. Minting additionally excludes Ada. A value can be
useful for calculations even when it does not satisfy those transaction rules.

Use byte or hex conversion for identity interchange. `Show` is diagnostic.
