# Message signing

`Cometa.Message.Cip8.sign` signs a nonempty binary payload using a scoped normal
or extended `Cometa.Crypto.Ed25519.SigningKey`. Use `addressBinding` with a
validated address or `keyHashBinding` with a role-specific `Credential.KeyHash`.
The result provides owned CBOR bytes in `coseSign1` and `coseKey`, suitable for
encoding as the signature/key fields of a CIP-30 data signature. Those bytes
remain usable after the key closes.

```{literalinclude} ../../examples/MessageSigning.hs
:language: haskell
:start-at: main ::
```

The payload is included directly, with `hashed = false` and empty external AAD.
This API does not offer detached payloads, prehashing or custom AAD. Empty
payloads return `NativeError` with `InvalidArgument`; escaped closed keys return
`SigningKeyClosed`.

The binding is recorded in signed headers. Signing does not check that the key
controls the address or matches the supplied hash; a verifier must check that
relationship as well as the COSE signature. The native key-hash form uses the
protected `address` field for the 28-byte hash. Both forms also include a key
identifier in COSE_Key; the full-address form includes a protected `kid` too.

The encrypted software handler supports transaction signing through its native
capability contract; it does not expose arbitrary-message signing. Applications
that derive scoped keys can call this module without exporting private bytes.
`examples/MessageSigning.hs` demonstrates a complete
key-hash workflow using a public, unfunded demonstration seed.
