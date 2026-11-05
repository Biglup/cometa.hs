# Stake pool registration parameters

Use `Cometa.Pool.Parameters` to assemble a registration from public hashes, a
reward account, an exact margin, owners, relays and optional metadata. Validation
is pure. The resulting record can be inspected and updated with ordinary record syntax.

The compiled `examples/StakePools.hs` example validates public fixture inputs,
assembles a registration, encodes and reloads its CBOR in memory, removes
metadata and encodes a `Certificate.PoolRegistration`. It uses no signing key
and submits nothing. One `Either Error` boundary covers input validation and
reloading; assembly and updates are total.

```{literalinclude} ../../examples/StakePools.hs
:language: haskell
:start-at: module Main
```

## Validate inputs once

An operator is a `Credential.KeyHash Credential.StakePool`, while owners are
`Credential.KeyHash Credential.Stake`. Both contain exactly 28 bytes. Import the
VRF verification-key hash with `Pool.vrfKeyHashFromBytes`, which requires 32 bytes.
Importing a digest does not hash or authenticate its source key.

`Unit.mkUnitInterval numerator denominator` validates the exact margin between
zero and one inclusive; no floating-point conversion occurs. Pledge and fixed
cost are `Word64` lovelace values. Construction does not establish that a pool satisfies an era's cost floor,
funding rules or registration requirements.

Owners use `Data.Set`, so repeated owners collapse and serialization sorts their
hash bytes. Relays use a list: their order and duplicates remain observable.

```haskell
let updated = parameters
      { Pool.metadata = Nothing
      , Pool.relays = additionalRelay : Pool.relays parameters
      }
    certificate = Certificate.PoolRegistration updated
```

Both expressions are total once their components are validated. Updating a
record leaves the original record and its encoding unchanged.

## Choose relay addresses

`Cometa.Pool.Relay` provides three relay alternatives:

| Constructor | Meaning |
| --- | --- |
| `SingleHostAddress port ipv4 ipv6` | Optional port and optional IP addresses |
| `SingleHostName port dns` | An A or AAAA record, with optional port |
| `MultiHostName dns` | A DNS SRV record supplying its own port |

Ports are `Maybe Word16`; zero and 65535 are representable. An IP relay may omit
all three components. `ipv4FromBytes` and `ipv6FromBytes` validate exactly four
and sixteen network-order bytes respectively. `ipv4FromText` accepts dotted
decimal. `ipv6FromText` accepts one- through four-digit hexadecimal groups, a single
`::` compression and an optional final dotted IPv4 address. Text observers return canonical dotted decimal or
lowercase fully expanded IPv6.

`mkDnsName` validates 1 through 64 UTF-8 bytes without NUL. It does not validate
DNS syntax or resolve the name.

## Attach metadata and BLS information

`Cometa.Pool.Metadata.mkUrl` accepts at most 128 UTF-8 bytes without NUL. Empty
locations are representable in the pool schema. This is distinct from governance
anchor URL validation. No URI syntax or network reachability check occurs.
`metadataHashFromBytes` imports exactly 32 digest bytes, and `hashData` computes
BLAKE2b-256 over exact payload bytes in `IO`. Assemble the reference with
`Metadata.Metadata location digest`. Fetching metadata and comparing its digest
remain caller operations. Hashing performs no JSON parsing or normalization.

`Cometa.Pool.BlsKey.mkBlsKey` accepts 96 public-key bytes followed by 48
possession-proof bytes. It checks lengths, not group membership or proof
validity. `Pool.blsKey = Nothing` describes registrations without this optional
Dijkstra field; `Just key` includes it after the VRF hash. Choosing a representation
does not establish acceptance in a particular ledger era.

## Persist and reload values

`Pool.encodeCbor` produces one definite array containing the nine pool fields,
or ten with BLS information. `Pool.decodeCbor` validates that entire array,
including nested relays, metadata, reward account, owner hashes and margin.
Malformed schemas, duplicate owner hashes and trailing bytes return
`InvalidPoolCbor`. Untagged owner sets and an explicit null BLS placeholder are
accepted; fresh encoding uses tag 258 and omits an absent BLS field.

The relay, metadata and BLS modules also expose standalone `encodeCbor` and
`decodeCbor`. These codecs return semantic values and do not preserve nonminimal
or indefinite input encodings. Preserve the enclosing original transaction or
certificate bytes when its identity matters; a fresh encoding can change it.

See [certificates](certificates.md) to embed registration parameters in a
certificate and retain imported certificate bytes.
