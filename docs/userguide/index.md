# Cometa.hs

Cometa.hs provides Ed25519 signing, CBOR encoding, and immutable Blake2b hashes,
backed by [cardano-c](https://github.com/Biglup/cardano-c). Operations report
structured errors.
The library is unpublished; build it from a checked-out source revision.

Start with [installation](installation.md), then read the
[hash guide](hashes.md), [CBOR guide](cbor.md), and [signing guide](signing.md), and [BIP32 derivation guide](bip32.md).
The [API reference](api-reference.md) explains how to browse the declarations for the revision you build.

```{toctree}
:maxdepth: 2
:caption: User guide

installation
hashes
cbor
signing
bip32
api-reference
```

```{toctree}
:maxdepth: 2
:caption: Contributors

development
```
