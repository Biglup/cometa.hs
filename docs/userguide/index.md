# Cometa.hs

Cometa.hs provides protocol parameters and governance votes, Plutus data, metadata
and scripts, asset values, Shelley addresses
and credentials, Ed25519 signing,
BIP39 recovery, BIP32 derivation, CBOR
encoding, and immutable Blake2b hashes,
backed by [cardano-c](https://github.com/Biglup/cardano-c). Operations report
structured errors.
The library is unpublished; build it from a checked-out source revision.

Start with [installation](installation.md), then read the
[hash guide](hashes.md), [CBOR guide](cbor.md), [signing guide](signing.md),
[BIP32 derivation guide](bip32.md), [BIP39 recovery guide](bip39.md),
[password crypto guide](password-crypto.md),
[software key-handler guide](software-key-handlers.md),
[address guide](addresses.md), [assets and values guide](assets-values.md),
[Plutus data guide](plutus-data.md), [metadata guide](metadata.md), and
[script guide](scripts.md), [protocol values](protocol-values.md),
[protocol parameters](protocol-parameters.md), and [governance votes](governance.md).
The [API reference](api-reference.md) explains how to browse the declarations for the revision you build.

```{toctree}
:maxdepth: 2
:caption: User guide

installation
hashes
cbor
signing
bip32
bip39
password-crypto
software-key-handlers
addresses
assets-values
plutus-data
metadata
scripts
protocol-values
protocol-parameters
governance
api-reference
```

```{toctree}
:maxdepth: 2
:caption: Contributors

development
```
