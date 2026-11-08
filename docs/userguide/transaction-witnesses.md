# Script witnesses and auxiliary data

A script witness combines the script, any datum, its indexed argument, and its
execution budget. Redeemer purposes distinguish spending, minting, certificates,
reward withdrawals, votes, proposals, and transaction guards. The index is the
zero-based position in the corresponding transaction-body collection. Evaluation
supplies the memory and CPU budget before signing.

Validate external bytes once, then assemble these components using the existing
script and Plutus-data types. `Witnesses.mkWitnesses` sorts redeemers by purpose
and index and rejects duplicate identifiers. Script and datum lists retain order
and duplicates. Plutus scripts are grouped by version in the witness map. These
standalone values do not establish whether a ledger era accepts a script version
or purpose.

`Witnesses.decodeCbor` retains the complete imported witness encoding.
`Witnesses.mergeEncoded` adds wallet-returned witnesses while preserving untouched
field bytes. Identical additions are idempotent. A different signature for the
same verification key, or a different argument or budget for the same redeemer
identifier, returns a conflict. Removing key witnesses leaves scripts, datums,
and redeemers intact.

Auxiliary data combines optional transaction metadata and auxiliary scripts.
`AuxiliaryData.decodeCbor` accepts historical metadata and metadata/script forms
as well as tagged auxiliary maps. Persist `toCbor` when exact bytes matter.
`AuxiliaryData.hash` hashes the full exact encoding, including scripts and the
outer envelope, through an explicit `IO` operation. Metadata bytes alone are not
the auxiliary-data hash input.

The following offline example assembles witnesses, reloads their stored bytes,
and hashes auxiliary metadata through one `ExceptT` error boundary. It uses no
keys or network access.

```{literalinclude} ../../examples/TransactionWitnesses.hs
:language: haskell
:start-at: "{-# LANGUAGE OverloadedStrings #-}"
```

## Collection tags

`Witnesses.encodeCborWith` selects tagged or untagged encoding for all present
witness sets. `Witnesses.setEncoding` observes one `SetField`, and
`Witnesses.withSetEncoding` edits it without changing nested script or datum bytes.
Redeemers are not controlled by this option. Absent collections remain absent.
Changing a datum-set representation can require a new script-data hash; update
that body commitment and sign again before submission.
