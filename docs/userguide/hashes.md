# Blake2b hashes

`Cometa.Crypto.Blake2b` provides an abstract `Blake2bHash` value. Use a qualified
import to keep conversions and operations easy to identify:

```haskell
import qualified Cometa.Crypto.Blake2b as Blake2b
```

A hash owns its bytes as a Haskell value. Callers do not allocate or release native
objects.

## Construct and inspect

`fromBytes` imports a nonempty byte sequence; `fromHex` imports nonempty,
even-length hexadecimal text. Both run in `IO` and return `Either`. Hex input
accepts uppercase and lowercase ASCII digits, without whitespace or a prefix.
These operations import an existing digest rather than hash a message. They do
not enforce a role-specific hash length. This general digest type is not a
payment, stake, or script hash.

`toBytes` returns the digest bytes, and `toHex` returns lowercase hexadecimal
text without a prefix.
Neither operation changes the value. Use these conversions for interchange;
`Show` is diagnostic output.

## Compute a digest

`compute` hashes a message using the native Blake2b implementation. Its type makes
the effect explicit: callers receive a result in `IO`, with expected failures
represented by `Either`. Its first argument selects a digest length from 16
through 64 bytes, and its second argument is the message as a `ByteString`.
The current native operation rejects an empty message.

The repository includes a complete runnable program in `examples/Hash.hs`:

```sh
cabal run cometa-hash -- "Hello, Cardano!"
```

It prints the linked native version and the 32-byte digest of the UTF-8 message.
Use the same native library options as for your build when needed.

`Cometa.nativeVersion` reports the linked native library version in `IO`.

## Handle errors

Inspect `Left` results using the error constructors from `Cometa.Error`.
`Right` contains a validated result. Keep invalid external input in the ordinary
error path; a failed conversion must not be treated as an empty hash.
