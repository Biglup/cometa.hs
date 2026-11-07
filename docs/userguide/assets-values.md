# Assets and values

Use `Cometa.AssetId` to identify Ada or a native token, and `Cometa.Value` to
assemble and inspect their quantities. Asset identities and values are immutable;
construction, arithmetic, and inspection are pure. Computing a fingerprint uses
`IO` and returns an explicit error result.

## Assemble a token payment

A native asset is identified by its 28-byte policy ID and asset name of up to
32 bytes. Validate these inputs once, then use `AssetId.Native policy name`
wherever the asset is needed. `AssetId.Ada` identifies Ada independently of any
policy or name. An empty name under a policy still identifies a native token.

The following example imports a policy and token name, combines Ada and token
quantities, computes the token balance after a payment, and displays the native
asset ID and fingerprint. It uses demonstration
values and makes no network requests.

```{literalinclude} ../../examples/AssetsValues.hs
:language: haskell
:start-at: "{-# LANGUAGE OverloadedStrings #-}"
```

Run it with:

```sh
cabal run cometa-assets-values
```

The example combines input validation and fingerprint hashing through `ExceptT`
and handles one `Either Error` result. Once the policy and name are
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

## Exchange full asset IDs and display fingerprints

`AssetId.fromBytes` imports the 28-byte policy ID followed by zero through 32
exact asset-name bytes. `AssetId.fromHex` imports the same bytes as contiguous
hexadecimal text, without a separator. Both preserve binary names and accept an
empty native name. Byte lengths outside 28 through 60 return
`InvalidAssetIdLength`; malformed hexadecimal returns `InvalidHex`.

`AssetId.toBytes` and `AssetId.toHex` return these native asset encodings; hex
output is lowercase. Ada has no representation in this format, so both exports
return `Left (UnsupportedOperation ...)` for `AssetId.Ada`. Empty bytes and empty
hex are rejected on import. Select `AssetId.Ada` explicitly when handling Ada.

Use `AssetId.fingerprint asset` to compute a CIP-14 display fingerprint. It returns
`IO (Either Error Text)` containing an `asset1...` Bech32 string for a native
asset, or `UnsupportedOperation` for Ada. The fingerprint hashes the policy and
exact name bytes with BLAKE2b-160. It cannot be decoded back to the full asset ID
and does not prove that a token is authentic. Keep the full policy and name for
identity interchange and transaction construction.

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
