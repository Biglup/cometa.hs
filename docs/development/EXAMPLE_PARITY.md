# C++ example parity

This audit uses the Apache-2.0 Cometa.cpp source snapshot
[`824ae8e8ac9adf113d957265532ae7ea37a628a3`](https://github.com/Biglup/cometa.cpp/tree/824ae8e8ac9adf113d957265532ae7ea37a628a3/examples).
All 21 example entrypoints and `examples/Support/NetworkExample.{h,cpp}` were
reviewed. The local read-only snapshot recorded the same revision in
`SOURCE_REVISION`. No encrypted funded-wallet fixture or private seed from that
snapshot was copied into the Haskell runners.

The live evidence below used cardano-c
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`. The current dependency is recorded in
`native/cardano-c.ref`; the construction completion revision has separate offline
validation and does not inherit a claim of new on-chain execution. Existing Haskell
`Workflows.Native` and `Workflows.NativeScripts` were inspected against the C++
caller workflows before reuse. Exact comparisons confirm that the 1,941-byte V2
reward program and 432-byte V3 withdrawal program match the corresponding C++
constants byte for byte. Script DRep, voting and treasury deployments come from
resolved caller-supplied chain references, rather than substituting trivial
fixture programs.

## Exact entrypoint inventory

Paths in the Haskell column are relative to `examples/`.

| C++ source in `examples/` | Haskell entrypoint | Workflow and material differences |
| --- | --- | --- |
| `bip39_example.cpp` | `WalletRecovery.hs`, `Bip39.hs` | Mnemonic to entropy, encrypted handler, account public derivation and base address. Recovery also reloads storage and signs an offline payment. |
| `secure_key_handler_example.cpp` | `WalletRecovery.hs`, `SoftwareKeyHandler.hs` | Encrypted serialization, reload and scoped signing, using an unfunded public demonstration fixture. |
| `provider_example.cpp` | `BlockfrostQueries.hs --query` | Parameters and configured payment/reward queries; Haskell provider capabilities are exercised separately. |
| `send_lovelace_example.cpp` | `Connected/SendLovelace.hs` | Configured recipient and amount; build, sign, submit and confirm. |
| `mint_burn_native_script_example.cpp` | `Connected/MintBurnNativeScript.hs` | Exact native before-script; mint BerryOnyx and BerryRaspberry, CIP-25 metadata and explicit two-ADA token output; burn Onyx only. |
| `mint_burn_plutus_script_example.cpp` | `Connected/MintBurnPlutusScript.hs` | Resolve the configured policy reference; mint both PlutusBerry assets with metadata; burn Onyx only, using the unit redeemer. |
| `spend_from_native_script_example.cpp` | `Connected/SpendFromNativeScript.hs` | Fund the source native script with two ADA, then spend with an explicit one-ADA payout. |
| `spend_from_validator_example.cpp` | `Connected/SpendFromValidator.hs` | Fund the pinned native-example V3 validator with two ADA and inline unit, create a fresh 30-ADA reference-script output, then reference-spend with a one-ADA payout. C++ instead resolves its historical deployment. |
| `deferred_redeemer_self_index_example.cpp` | `Connected/DeferredRedeemerSelfIndex.hs` | Fund the actual V3 self-index validator with two ADA; attach it inline and send an explicit one-ADA payout; callback finds its canonical input index in the balanced transaction. |
| `deferred_redeemer_batch_example.cpp` | `Connected/DeferredRedeemerBatch.hs` | Fund two source V3 order-pairing validators with two ADA each; attach the validator inline and pay 1.2/1.5 ADA; callbacks find each canonical input and payout index for joint settlement. |
| `deferred_redeemer_withdraw_zero_example.cpp` | `Connected/DeferredWithdrawZero.hs` | Register and delegate the exact V3 reward script; deferred redeemer lists actual sorted input indexes; withdraw zero and unregister. |
| `reward_account_pubkey_example.cpp` | `Connected/RewardAccountPubkey.hs` | Register fresh derived stake authority, delegate stake and voting power to AlwaysAbstain, withdraw and unregister. Queries actual rewards rather than assuming zero. |
| `reward_account_script_example.cpp` | `Connected/RewardAccountScript.hs` | Register and stake-delegate the exact V2 script; script withdrawal and cleanup. Omits voting delegation, matching this source. |
| `drep_pubkey_example.cpp` | `Connected/DRepPubkey.hs` | Register derived role-three DRep; register/delegate fresh stake authority; withdraw and clean up stake; clean up DRep. |
| `drep_script_example.cpp` | `Connected/DRepScript.hs` | Resolve the configured V3 DRep program and attach it inline, matching C++ `addScript`; perform the same four-stage cycle. |
| `vote_for_proposal_pubkey_example.cpp` | `Connected/VoteForProposalPubkey.hs` | Register derived DRep, vote Yes on the configured action, then unregister. |
| `vote_for_proposal_script_example.cpp` | `Connected/VoteForProposalScript.hs` | Resolve the V3 DRep program, attach it inline and use the unit redeemer for registration, Yes vote and cleanup. |
| `donate_to_treasury_example.cpp` | `Connected/DonateToTreasury.hs` | Donate exactly two ADA. |
| `propose_treasury_withdrawal_example.cpp` | `Connected/ProposeTreasuryWithdrawal.hs` | Preserve the actual constitution reference input and check its hash. Configure return account and amount explicitly; C++ uses 1,000,000,000,000 lovelace. This submits a proposal, not a treasury transfer. |
| `sub_transaction_batch_example.cpp` | `NativeSwap.hs` | The C++ source is an offline buyer/seller/batcher exchange. Haskell independently signs both local intents and checks preservation and conservation. |
| `plutus_v4_guarded_sub_transaction_example.cpp` | `Connected/PlutusV4GuardedSubTransaction.hs` and offline guarded-subtransaction tests | Source V4 validator and distinct guard, signed local intent and enclosing batch. Connected runner rejects protocol below 12 before funding. |

## Shared execution and deliberate refinements

`Connected.Support` owns the configured provider and encrypted handler scopes.
The signer covers payment plus selected stake and DRep paths, budgeting for two
additional witnesses. Authority indexes default to 701 and can be changed; the
funded wallet remains account zero, payment zero and base stake zero.
`--describe` exposes only public identities. `--submit` executes the complete
named flow and journals accepted and confirmed transaction IDs before later
stages can fail.

The validator-spending runner deliberately deploys a fresh reference output carrying
its pinned native-example V3 program, instead of depending on the historical
reference resolved by the C++ example. It leaves 30 ADA in a key-controlled
reference output, which can be retained or spent later. The deferred self and
batch examples use the source's two-ADA locks and inline witnesses, without
creating reference deployments. Their explicit payouts are one ADA for self-index
and 1.2/1.5 ADA for the pair.

`COMETA_COLLATERAL` is resolved independently and excluded from ordinary spending.
`COMETA_RESERVED_INPUTS` preserves reusable outputs across independent flows while
still allowing explicit resolution. CIP-25 metadata uses the actual policy hash
rather than copying the C++ example's unrelated illustrative policy key.

`Workflows.Native.runStage` distinguishes confirmation from address indexing. It
waits on idempotent address queries until all exact newly created wallet outputs
appear and consumed wallet references disappear. It never retries a submission
after an uncertain outcome. Confirmation and indexing each use bounded waits.

Governance recipes query current registration deposits once and retain those
amounts for cleanup. A zero reward balance is not proof of an unregistered
account. The existing provider record does not expose active-pool status, stake
registration state, DRep registration/deposit state, action eligibility/expiry or
current constitution policy. Live execution therefore needs independent current
chain queries for those facts. Fixed script identities are discovered and queried
as scripts; fresh key indexes do not make a fixed script new.

The treasury recipe corrects an older helper's reference-witness difference: it
uses the actual reference input rather than attaching the constitution program
inline. It checks the configured constitution hash before submission. Proposal
deposits and eventual reward-account access remain part of the caller's chosen
workflow. A failed later stage leaves earlier confirmed registrations intact;
the journal and original deposit amounts support recovery.

## Verification and live evidence

The connected sources have offline recipes and fixture tests, including native
script evaluation, cryptographic signatures and conservation checks.
`ConnectedGovernance` adds the nine staking/governance recipes, constitution-hash
rejection before submission, treasury reference-input preservation and public
identity discovery. The fixture does not emulate ledger registration, pool or
governance state. Source, formatting and test results must be recorded alongside
actual execution evidence; source parity alone is not live validation.

The [PR #22 validation record](https://github.com/Biglup/cometa.hs/pull/22)
tracks this pass's network/protocol, transaction IDs, ledger validity and cleanup
results. Its live status is separate from the source mapping above. Earlier
provider endpoint validation does not establish successful execution of these
workflows. Registration deposits must be distinguished from a governance
proposal deposit, which remains locked until the proposal reaches its outcome.

Protocol 11 preprod cannot validate the Dijkstra transaction bodies. The offline
atomic-swap and guarded-subtransaction tests remain applicable; a protocol gate
or offline pass must not be reported as a successful live Dijkstra submission.

Live V2 staking found that repeated script attachments produced duplicate CBOR
witness-set elements despite successful local evaluation. Shared plan normalization
now makes repeated script attachments idempotent by language and script identity.
The related datum path coalesces exact datum bytes across explicit attachments and
spending inputs, preserving each input and deferred callback. Builder regressions
cover both top-level and subtransaction plans; the live validation record includes
the corrected staking cycle. No funded-wallet fixture was added to the tests.
