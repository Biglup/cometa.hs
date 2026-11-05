# Shelley addresses and credentials

`Cometa.Address.Shelley` constructs, inspects, and encodes base and enterprise
payment addresses. `Cometa.Address.Reward` handles staking reward accounts.
`Cometa.Credential` describes their payment or staking authority.

| Form | Payment credential | Stake credential | Use |
| --- | --- | --- | --- |
| Base | Required | Required | Receive payments associated with staking rights |
| Enterprise | Required | Absent | Receive payments without staking rights |
| Reward | Absent | Required | Identify a staking reward account |

Both credential positions accept key or script credentials. Payment addresses
have type `Address`; reward accounts have the distinct type `RewardAddress`.
Pointer and Byron addresses are outside these modules' supported forms.

## Create a receiving address

A key credential contains the 28-byte BLAKE2b hash of an Ed25519 public key.
Use `Credential.fromPublicKey` to hash a public key and obtain a
`Credential Payment` or `Credential Stake`, then assemble an address with
`Address.base network payment stake`.

The following example derives payment and stake public keys from deterministic
demonstration entropy, converts them to credentials, and prints a test-network
base address. It makes no network requests. For application key derivation,
see the [BIP32 guide](bip32.md).

```{literalinclude} ../../examples/Addresses.hs
:language: haskell
:start-at: "{-# LANGUAGE OverloadedStrings #-}"
```

Run it with:

```sh
cabal run cometa-addresses
```

`ExceptT` sequences the fallible operations with one error boundary. Hash import
validates the encoded length; assembling an address from validated values is
total. An address does not prove that anyone controls its keys or that a script
can be satisfied.

## Choose credentials and a network

`Credential Payment` and `Credential Stake` distinguish the two authorities.
Their key hashes have distinct types. When importing an existing hash with
`keyHashFromBytes`, choose the role from the key's intended use; the hash bytes
themselves do not encode a role. Wrap the result in `KeyCredential`.
A `ScriptHash` is also exactly 28 bytes and can be used in either
position through `ScriptCredential`. `scriptHashFromBytes` imports an existing
hash; it does not hash script bytes.

Use `Address.enterprise network payment` for an address without staking rights.
`Address.paymentCredential` always returns its payment authority;
`Address.stakeCredential` returns `Nothing` for enterprise addresses and `Just`
the staking authority for base addresses.

For a reward account, use `Reward.fromCredential network stake` from
`Cometa.Address.Reward`. Its `credential` observer always returns the staking
authority. The separate `RewardAddress` type keeps reward accounts distinct
from payment destinations.

`Address.mainnet` is network ID 1; `Address.testnet` is network ID 0.
These values and their type are defined in `Cometa.NetworkId`, and re-exported
by `Cometa.Address.Shelley`. `mkNetworkId` accepts integers from 0 through 15,
the four-bit network tag carried by an address. This is different from the
network magic used to configure a node connection. A test-network address does
not identify preprod or preview;
select the intended network separately in the application connecting to it.

## Read and write addresses

Both address modules provide `toBytes` and `fromBytes` for exact byte conversion
without effects.
Base addresses contain 57 bytes; enterprise and reward addresses contain 29.
`fromBytes` rejects empty, truncated, or trailing input with
`InvalidShelleyAddress`. Unsupported address headers return
`UnsupportedAddressType` with the header's address-type tag. Each module rejects
the other address family's headers.

Bech32 conversion is also pure: `toText` returns `Text`, and `fromText` returns
`Either Error ...`. Text output is lowercase. Network ID 1 uses `addr` for payment
addresses and `stake` for reward accounts; every other network ID uses `addr_test` and
`stake_test`. Text input accepts lowercase or all-uppercase Bech32 with a matching
prefix and checksum; uppercase input is normalized. Mixed-case, non-ASCII,
empty, and overlong inputs are rejected; the maximum accepted length is 120
characters. Invalid encoding, case, prefix, or checksum returns
`InvalidShelleyAddressText`.

Use `toText` for address interchange. `Show` is diagnostic. In the example,
key derivation and `Credential.fromPublicKey` return failures in `IO`; address
assembly and rendering use the resulting values directly. Callers do not manage
address lifetimes.
