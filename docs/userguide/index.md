# Cometa.hs

Cometa.hs provides typed transactions and signing, Cardano protocol values,
staking certificates, pool registrations,
governance proposals and votes, scripts and metadata, addresses and assets,
and key management and cryptography,
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
[protocol parameters](protocol-parameters.md), [governance votes](governance.md),
[stake pools](stake-pools.md), [certificates](certificates.md), and
[governance proposals](governance-proposals.md). For transaction workflows, see
[transaction bodies](transaction-bodies.md), [transactions](transactions.md), and [witnesses](transaction-witnesses.md).
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
stake-pools
certificates
governance-proposals
transaction-bodies
transactions
transaction-witnesses
providers
coin-selection
evaluation-and-signing
api-reference
```

```{toctree}
:maxdepth: 2
:caption: Contributors

development
```
