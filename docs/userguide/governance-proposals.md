# Governance proposals

A proposal combines its deposit in lovelace, the reward account that receives the
returned deposit, an action and an off-chain metadata anchor. Obtain the required
deposit from the protocol parameters for your target network before assembling a
transaction. These standalone values do not establish eligibility or submit a
transaction.

Validate runtime inputs with `Reward.fromBytes`, `Anchor.mkUrl`,
`Anchor.dataHashFromBytes` and the credential/hash constructors. Then assemble
an action and proposal with total constructors:

```haskell
let changes = Update.empty {Update.updateMinFeeB = Just 155381}
    action = Action.ParameterChange Nothing changes Nothing
    proposal = Proposal.Proposal deposit returnAccount action anchor
    proposals = Proposal.fromList [proposal]
    bytes = Proposal.encodeProposals proposals
```

`examples/GovernanceProposals.hs` contains the complete offline workflow with
explicit imports, deterministic public fixtures, serialization and reload.

`Cometa.Governance.Action` represents all seven action kinds: parameter change,
hard-fork initiation, treasury withdrawals, no confidence, committee update,
new constitution and information. Optional predecessor identifiers use `Nothing`
to start a chain. Parameter and treasury actions can include an optional
28-byte guardrails script hash. `Constitution.Constitution` holds an anchor and
an optional guardrails script hash. Committee changes use cold credentials;
committee votes use hot credentials.

Construct membership with `Committee.membersFromList` and withdrawals with
`Action.withdrawalsFromList`. Repeating a map key returns a structured error,
even when the associated values agree. Membership expiry epochs, deposits,
withdrawals and legacy activation epochs retain the unsigned 64-bit range;
withdrawal zero is distinct from absence. `UnitInterval.mkUnitInterval` validates
a quorum between zero and one before total committee assembly. Removal
credentials sort by kind and hash while retaining repeated credentials.

`Proposal.fromList` preserves order and duplicate proposals. Their positions
identify the proposals within a transaction, so sorting or removing an entry
changes proposal identities. `Proposal.append` concatenates collections and
has `Proposal.empty` as its identity. Fresh collection encoding includes CBOR
set tag 258, without treating the sequence as a mathematical set.

`Action.decodeCbor`, `Proposal.decodeCbor` and `Proposal.decodeProposals` retain
exact imported bytes. Inspect semantic values with `toAction`, `toProposal`
and `toProposals`; retrieve the original encodings with `toCbor` or
`proposalsCbor`. Fresh encoders normalize integer widths, containers and map
order. Re-encoding semantic data from an existing transaction can change its
identity, so keep the exact enclosing transaction bytes when identity matters.
Decoders accept nonminimal integers and definite or indefinite containers,
reject unknown action codes, incorrect arities, invalid components, duplicate
map keys and trailing data, and report `InvalidProposalCbor`.

`Cometa.Protocol.ProposedUpdates` covers the separate legacy format: a map of
28-byte genesis key hashes to sparse `Parameters.Update` values and an
`UpdateProposal` activation epoch envelope. `fromList` rejects duplicate genesis
keys. `decodeCbor` and `decodeProposal` preserve their exact bytes; `toUpdates`
and `toProposal` inspect meanings. This legacy envelope is distinct from a
Conway parameter-change governance action.
