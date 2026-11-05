# Assemble and reload certificates

Use `Cometa.Certificate` to assemble staking, pool and governance certificates
from validated credentials, pool parameters, DRep targets and anchors. Construction
is pure. Deposits, refunds and reward quantities count lovelace and range from
zero through `2^64 - 1`; retirement epochs use the same unsigned bound. Obtain
required deposits and refunds from the protocol parameters and current ledger
state in your transaction workflow.

The compiled example `examples/Certificates.hs` validates external hashes and an
anchor, registers a DRep and delegates a stake credential to it. One `Either`
boundary handles validation and reloading errors. The supplied hashes and deposit
are demonstration data. Metadata hashes identify the exact off-chain payload;
importing a hash does not verify a payload or fetch the URL.

```haskell
let authority = Credential.KeyCredential representative
    metadata = Anchor.Anchor location digest
    registration = Certificate.RegisterDRep authority deposit (Just metadata)
    delegation = Certificate.VoteDelegation stake (DRep.DRepCredential authority)
    certificates = Certificates.fromList [registration, delegation]
    stored = Certificates.encodeCbor certificates
reloaded <- Certificates.decodeCbor stored
```

Here `Certificate`, `Certificates`, `Credential`, `Anchor` and `DRep` are qualified
imports of `Cometa.Certificate`, `Cometa.Certificate.Collection`,
`Cometa.Credential`, `Cometa.Governance.Anchor` and `Cometa.Governance.DRep`.
Validated inputs assemble without another failure branch. A special target such
as `DRep.AlwaysAbstain` can receive delegation but cannot register as a DRep.
Committee authorization uses separate cold and hot credential roles.

`PoolRegistration` takes the complete `Pool.PoolParameters` value described in
[stake pools](stake-pools.md). A pool retirement takes the operator key hash and epoch.
The ADT also covers legacy stake registration/deregistration, genesis delegation,
and both instantaneous reward transfer forms. `ToOtherPot source amount` moves
from its source to the other pot. `ToStakeCredentials source rewards` uses a
`Map` of unique stake credentials to unsigned amounts; signed reward adjustments
are rejected during decoding. These shapes do not establish era eligibility or
ledger acceptance. Witnesses, registration state and protocol checks belong to
the surrounding transaction workflow.

A collection preserves order and repeated certificates. Fresh encoding writes
set tag 258 and a definite array. The decoder accepts tagged or untagged arrays,
including indefinite forms and nonminimal integers, while checking certificate
kind, field arity, hash lengths and unsigned numeric bounds. Malformed data and
trailing bytes return `InvalidCertificateCbor`. Duplicate MIR reward credentials
are rejected.

`Certificate.decodeCbor` returns an `EncodedCertificate` and
`Certificates.decodeCbor` returns `EncodedCertificates`. Their `toCbor` functions
return the exact original bytes. Inspect fields through `toCertificate` or
`toCertificates`; fresh `encodeCbor` creates a new encoding. A null pool BLS slot
is accepted as absence and omitted by fresh encoding. Keep the exact enclosing
transaction CBOR whenever transaction identity or signatures must be preserved.
Changing a certificate requires the transaction workflow to rebuild and sign the
transaction; this example only assembles and reloads standalone certificate data.
