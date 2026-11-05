# Scripts

Use `Cometa.Script.Native` for signature, time and guard conditions, and
`Cometa.Script.Plutus` for compiled Plutus programs. Values are immutable; script
assembly, inspection and byte conversion are pure. Hashing and program parameter
application return `IO (Either Error ...)`.

## Assemble a policy and apply program parameters

The example constructs a signature policy restricted to slots 100 through 199,
hashes it, then applies a data constant to a compiled Plutus identity program and
hashes the resulting program. It prints two policy IDs using demonstration
values, with one error boundary and no network requests.

```{literalinclude} ../../examples/Scripts.hs
:language: haskell
:start-at: "module Main"
```

Run it with:

```sh
cabal run cometa-scripts
```

A script hash converts directly to a policy ID with `PolicyId.fromScriptHash`.
It can also supply `Credential.ScriptCredential` when constructing an address.
Hashing a script does not prove that a transaction satisfies its conditions.

## Construct native conditions

`Native.signature` accepts a validated `KeyHash Payment`.
`Native.allOf`, `Native.anyOf` and `Native.atLeast` preserve child order and
repeated children. `allOf []` succeeds and `anyOf []` fails.
`atLeast required children` accepts an unsigned 64-bit count; zero succeeds, and
counts above the number of children express a deliberately impossible condition.
No additional validation is needed when composing these values.

`Native.invalidBefore slot` sets an inclusive lower slot bound;
`Native.invalidAfter slot` sets an exclusive upper slot bound. Slots use
`Word64`, including zero and its maximum value. When importing an application
integer, check its unsigned 64-bit range before conversion rather than using
`fromInteger` unchecked.

`Native.requireGuard` accepts `Credential Guard`, with either key or script
authority. Guard conditions require Dijkstra ledger support. Values can be
constructed without asserting that a particular network or transaction era
supports them. `Native.view` exposes all seven alternatives and their children
for inspection, while the script constructor remains abstract.

## Keep compiled bytes and CBOR layers distinct

`Plutus.fromBytes version compiled` accepts nonempty opaque compiled bytes and
records V1, V2, V3 or V4. `Plutus.toBytes` returns those exact bytes. These operations
do not validate executable code or check that its declared version is available
in a transaction era.

Compiled Plutus bytes normally contain a single CBOR bytestring around Flat
code. `Plutus.encodeCbor` adds the outer bytestring used by script serialization.
For example, compiled bytes `450100002499` encode as `46450100002499` at this outer
level. Choose the operation from the format supplied by your caller; import never
silently unwraps or guesses a CBOR layer.

`Native.decodeCbor` and `Plutus.decodeCbor` require exactly one correctly shaped
script and reject trailing bytes. They preserve the exact imported encoding,
including nonminimal lengths and indefinite forms. `Native.encodeCbor` also
preserves each imported child's bytes when assembling a new parent.
Equality and ordering compare representations, so equivalent encodings can be
distinct Haskell values. A Plutus hash uses the version and compiled bytes;
differences only in its outer bytestring encoding do not change its hash.
Native hashes use the entire exact native script encoding.

Use `Script.Native` and `Script.Plutus` when an API accepts either alternative.
`Script.encodeCbor` writes `[language, payload]` with native tag zero and Plutus
tags 1 through 4. `Script.decodeCbor` validates the envelope and payload. This
combined envelope is normalized on encoding; the payload retains its exact
encoding. The envelope does not contribute to the script hash.

## Apply typed data constants

`Plutus.applyParams script parameters` applies `Cometa.PlutusData` constants in
list order. The first parameter becomes the innermost application, and the result
retains the declared version. This operation decodes and re-encodes the program,
even for an empty parameter list, so it can normalize program encoding and change
its bytes. The original value remains unchanged.

Malformed programs return a structured native error. Successful decoding does
not establish ledger validity, script execution success or compatibility with
the declared version. Parameter values preserve data-list order and arbitrary
integer precision.
