# Governance identities and voting

Use `Cometa.Governance.Voting` to associate a voting choice with a voter and a
proposal identifier. Validate external identities and metadata locations once;
assemble the resulting values with total constructors. Pure construction and
CBOR conversion use Haskell-owned values. Hashing off-chain metadata is an
`IO (Either Error ...)` operation.

## Prepare a vote with an explanation

This example builds a DRep vote, hashes an off-chain explanation, serializes the
votes for storage, and reloads them through the validating decoder. A single
`ExceptT` sequence collects expected failures. It uses demonstration hashes and
makes no network requests.

```{literalinclude} ../../examples/Governance.hs
:language: haskell
:start-at: "module Main"
```

Run the compiled example with:

```sh
cabal run cometa-governance
```

`VotingProcedure Yes Nothing` is a complete vote without an off-chain
explanation. `Abstain` is an explicit voting choice; leaving a voter/action pair
out of a collection means there is no vote from that authority on that action.
Encoding these values does not sign, submit or establish ledger acceptance of a
transaction.

## Choose the authority and action

`CommitteeVoter` accepts `Credential CommitteeHot`, `DRepVoter` accepts
`Credential DRep`, and `StakePoolVoter` accepts `KeyHash StakePool`. These roles
prevent a staking, payment or other authority from being used by accidental type
coercion. Importing 28 validated bytes assigns the role required by the caller;
it does not demonstrate possession of a signing key. Script credentials use the
existing validated `ScriptHash` type.

`Cometa.Governance.DRep` models delegation targets separately. `DRepCredential`
selects a registered key or script authority; `AlwaysAbstain` and
`AlwaysNoConfidence` are predefined delegation targets and cannot cast votes.

`TransactionId.fromBytes` requires exactly 32 bytes; `fromHex` requires 64
hexadecimal digits. `ActionId transactionId index` uses a zero-based `Word64`
index, including its full unsigned range. A particular ledger era can impose a
narrower proposal-index range. Validate arbitrary application integers before
converting them to `Word64`.

## Validate off-chain metadata

`Anchor.mkUrl` accepts 1 through 128 UTF-8 bytes with no NUL. It checks byte
length and safe representation, without URI syntax, content, or reachability
checks. The payload hash contains exactly 32 bytes. `Anchor.hashData` hashes the
exact supplied payload with BLAKE2b-256 without parsing or normalizing JSON.
Empty payloads return the existing native BLAKE2b error. `dataHashFromBytes`
imports a digest without computing or verifying it. An anchor authenticates
retrieved metadata only when the caller checks those payload bytes against the
expected digest.

## Combine votes explicitly

`Voting.singleton` cannot fail. `Voting.fromList`, `insert` and `merge` reject
repeated voter/action pairs with `DuplicateGovernanceVote`, even when the votes
agree. Other actions from the same voter are allowed. `lookup` returns `Nothing`
for an absent pair; `toList` orders entries by voter kind and hash, then proposal
transaction hash and numeric index. Disjoint merges are associative and
commutative and have `empty` as their identity.

## Preserve imported encoding identity

`Voting.decodeCbor` validates one complete nested voting map and returns an
`EncodedVotingProcedures`. `toVotingProcedures` inspects its semantic content;
`toCbor` returns the exact imported bytes. Equality of encoded wrappers compares
bytes, while equality of semantic collections compares votes.

The decoder accepts definite and indefinite containers and nonminimal unsigned
encodings. It rejects repeated outer voter keys, repeated action keys within a
voter, empty inner maps, invalid identities and anchors, unsupported codes, and
trailing bytes. These rejections avoid ambiguous or lossy vote reconstruction.

`encodeCbor` assigns fresh definite containers, shortest integers and sorted
maps to a semantic collection. Re-encoding inspected values can change the bytes
of a transaction containing them. Keep the encoded wrapper when preserving an
existing transaction's identity. Scalar anchor, action, DRep, voter and procedure
decoders return semantic values; preserve their original enclosing encoding
when identity matters.

## Diagnostic labels

`Cometa.Diagnostics.certificateKind`, `nativeScriptKind`, `vote` and `voterKind`
produce English category labels for logs and errors. They include no credential
hashes or payloads and do not depend on a type's derived `Show` representation.
These labels use cardano-c's diagnostic vocabulary; use the domain encoders or
inspection output when a structured interchange format is required.
