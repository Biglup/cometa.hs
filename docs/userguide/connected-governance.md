# Connected staking and governance examples

The nine runners in `examples/Connected` port the corresponding Cometa.cpp
examples from revision `824ae8e8ac9adf113d957265532ae7ea37a628a3`. Run a runner
without arguments for configuration help. `--describe` prints public identities
for chain-state discovery; `--submit` executes the complete workflow on the
configured preprod wallet. Wallet storage and passwords come from the shared
connected support configuration and are never embedded in these sources.

The shared wallet runner derives payment, stake and DRep authorities inside the
key-handler scope. Configurable stake and DRep indexes allow separate credentials
for each registration cycle. A fixed script has a fixed identity: changing a key
index does not change either script reward account. Current registration state,
active pools, proposal eligibility and constitution state must come from chain
queries; these examples do not infer them from a zero reward balance. The
provider's reward query alone does not establish whether an account is registered.

| Runner source | Confirmed stages | Required flow configuration |
| --- | --- | --- |
| `RewardAccountPubkey.hs` | Register, delegate stake and voting power; withdraw and unregister | `COMETA_POOL_ID_HEX` |
| `RewardAccountScript.hs` | Register and delegate the source V2 script; withdraw and unregister | `COMETA_POOL_ID_HEX` |
| `DeferredWithdrawZero.hs` | Register/delegate the source V3 script; deferred zero withdrawal and unregister | `COMETA_POOL_ID_HEX` |
| `DRepPubkey.hs` | Register DRep; register/delegate stake; clean up stake; clean up DRep | Fresh derived stake and DRep credentials |
| `DRepScript.hs` | The same four stages with the reference-sourced V3 DRep | `COMETA_GOVERNANCE_REFERENCE` |
| `VoteForProposalPubkey.hs` | Register DRep; vote Yes; unregister | `COMETA_GOVERNANCE_ACTION` |
| `VoteForProposalScript.hs` | The same three stages with the reference-sourced V3 DRep | `COMETA_GOVERNANCE_ACTION`, `COMETA_GOVERNANCE_REFERENCE` |
| `DonateToTreasury.hs` | Donate two ADA | Shared wallet configuration |
| `ProposeTreasuryWithdrawal.hs` | Submit a treasury withdrawal proposal with the actual constitution reference input | Treasury configuration below |

Input references and governance action IDs use `TXID#INDEX`. Pool IDs use their
28-byte hexadecimal hash. The script DRep and vote runners resolve the configured
reference and attach its V3 program inline, matching the C++ source. Treasury
uses the reference input itself and checks its script against
`COMETA_CONSTITUTION_SCRIPT_HASH`.

Treasury also requires `COMETA_CONSTITUTION_REFERENCE`,
`COMETA_TREASURY_RETURN_ACCOUNT` and `COMETA_TREASURY_WITHDRAWAL_LOVELACE`. The
last value is the proposed withdrawal amount; the C++ example uses
`1000000000000`. Submission pays transaction fees and locks the current governance
proposal deposit. It does not immediately withdraw the requested treasury funds.
Choose an account whose future reward-account access is available to the caller.
The policy hash and reference must match the current constitution rather than a
historical example deployment.

Each cycle queries current parameters and retains its registration deposits for
cleanup. It queries reward balances before cleanup where appropriate. The
withdraw-zero validator deliberately requests exactly zero and assumes the script
account has no outstanding rewards. It constructs its deferred redeemer from the
actual balanced inputs' sorted canonical indexes.

The shared provider journal records accepted transaction IDs and confirmation
results at every stage. A later failure stops dependent submissions and does not
roll back earlier confirmed registrations. Use the recorded transaction IDs,
public identities and registration deposit amounts to inspect and finish cleanup;
rerunning a cycle from its beginning against an existing registration is not a
recovery procedure. An uncertain submission result must be resolved before
resubmitting those signed bytes.

`test/ConnectedGovernance.hs` executes these recipes with the offline provider,
including native evaluation, signatures, conservation, treasury reference
preservation and constitution-hash rejection. That fixture does not emulate pool,
registration or governance ledger state. Live results must be recorded separately.

The two Dijkstra C++ examples use subtransactions and Plutus V4. Those workflows
are tested offline with the existing signed-batch and guarded-subtransaction
examples. They require a protocol supporting those ledger features; protocol 11
preprod results do not establish live Dijkstra support.
