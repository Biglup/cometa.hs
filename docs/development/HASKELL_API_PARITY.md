# Haskell API capability parity audit

This is a source-based gap analysis, reviewed 2026-11-07. The target is complete
coverage of existing cardano-c domain capabilities and supported transaction
construction, with small Haskell conveniences. The comparison below also records
optional upstream capabilities; its gaps are not all delivery requirements.

The maintainer explicitly excluded larger infrastructure on 2026-11-07:
local-node/Ouroboros connectivity, chain synchronization and rollback services,
full ledger validation/emulation, devnet orchestration, additional built-in
provider backends, and associated CLI/RPC/WASM applications. These are comparison
context, not implementation backlog or release gates. Existing provider injection
and Blockfrost/custom URLs remain supported; additional queries are future work.

Seed/entropy generation is intentionally outside the base library. Applications
supply securely sourced entropy or existing key material; the library provides
validation, mnemonic conversion and derivation. Bindings must preserve this
boundary rather than introduce automatic seed-generation helpers as a coverage
requirement. This does not prohibit randomness needed by existing cryptographic
operations, such as encryption salts and nonces.

The comparison baseline is the current default-branch source resolved on the
review date, not an assumed Hackage release. sc-tools and Atlas pin older
cardano-api dependencies than the separately reviewed current cardano-api. A
capability present in the latter is not automatically present in those snapshots.

| Source | Exact reviewed revision | Boundary |
| --- | --- | --- |
| input-output-hk/sc-tools | 4546122230491db4839a4a42fc2bc601f7900909 | All package manifests, public module inventory, relevant implementation and README workflows; its cardano-api dependency is 11.0.0.0. |
| geniusyield/atlas | c3adfb416242ea25a244bfaa1614213eecdc55d9 | atlas-cardano public modules, builder/query/provider/type/testing implementations and Gift workflow; package constrains cardano-api to 10.13.1. |
| IntersectMBO/cardano-api | c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a | Traditional and experimental APIs, key/serialization, query/IPC and ledger services; related RPC/WASM packages are called out separately. |
| IntersectMBO/cardano-addresses | 5bca1736741413802f5b5aa96d0be9747f89f03c | Public library and CLI families, derivation styles, dictionaries and script templates. |
| Cometa.hs | Working tree based on merged PR21 | Public modules, existing named tests and implementation-plan restrictions; no new test run is claimed by this document. |
| cardano-c | eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1 | Installed public native API, not private UPLC/VM implementation headers. |

## How to read the comparison

**Implemented** identifies a concrete matching caller capability and evidence,
not equality of every upstream function or representation. **Partial** means a
caller can perform some of the workflow but a material operation or contract is
missing. **Missing** means there is no corresponding public Cometa workflow.
**Deferred** identifies a consciously postponed convenience; it does not block
the current delivery scope. **Out of scope** identifies infrastructure explicitly
excluded by the maintainer; it does not count as missing binding functionality.

This document groups meaningful operations, rather than counting aliases,
instances, lenses, enum variants or private reference-count functions. The group
IDs are stable review targets, not a denominator for a percentage. An exhaustive
export-by-export correspondence within the agreed scope, supported versions and
acceptance tests would still be required before a function-level 100% claim.
The native symbol ledger is a separate denominator.

The tables cite the pinned source catalog below. Local test paths are evidence
that test cases exist; their current passing status belongs to the build/CI
report. A native oracle verifies binding correspondence, not independent ledger
validity or parity with all upstream ledger versions.

## Transaction and script application workflows

| ID / capability | Primary source evidence | Existing Cometa surface and tests | Status and concrete remaining work |
| --- | --- | --- | --- |
| T01 Assemble payments, native assets, references, validity, metadata and required keys | S1; A1/A3; C1/C2 | Transaction.Plan, Builder, Output, Datum; test/TransactionBuilder.hs, test/TransactionBody.hs, test/Metadata.hs | **Implemented** for native-supported fields. There is no claim that every historical-era construction accepted by cardano-api is supported. |
| T02 Native/Plutus spend and mint, inline/hash datums, reference scripts | S1 spendPlutusRef/spendSimpleScript/mintPlutus; A7; C1 | Plan.spendWith, mintWithRedeemer, attachScript/referenceInput; Script.Native/Plutus; test/NativeWorkflows.hs, test/Scripts.hs, test/DeferredRedeemer.hs | **Implemented** explicit script/data workflow, including binary names. Compiled Haskell script types and automatic ToData conversion are separate gaps T07/T08. |
| T03 Coin selection, collateral, change, fee and minimum UTxO iteration | S2 balanceForWallet; A3 buildTxLoop; C2/C15 | CoinSelection and native strategy adapters, Transaction.Building/Builder; test/NativeCoinSelection.hs, test/TransactionBuilding.hs, test/TransactionBuilder.hs | **Implemented** native balancing workflow; algorithm choices and failure results need not match upstream. Atlas' additional configurable strategy space is not automatically covered. |
| T04 Local script evaluation and remote evaluation | S2; C2/C15 | Evaluation records, Evaluation.Native, optional Blockfrost provider; test/Evaluation.hs, test/NativeEvaluation.hs, blockfrost-test/BlockfrostJson.hs | **Partial.** Native V1–V4 evaluation and target budgets exist. Configurable VM ceilings, detailed successful traces/profiling and upstream error payloads do not. Blockfrost adapter uses Ogmios v5 additional-UTxO grammar and explicitly rejects unsupported newer purposes/scripts; it is not general remote V3/V4/Dijkstra evaluation. |
| T05 Deferred redeemers and canonical contextual indices | S1 WithRedeemerFn and lookupIndex helpers; C1 witness indexing | Top/sub Plan deferred operations, Transaction.Indices/SubTransaction.Indices; test/DeferredRedeemer.hs, test/TransactionIndices.hs, test/ContextualTransaction.hs | **Implemented** explicit snapshots and total lookups. Index conventions are native ledger ordering, not Haskell Ord of unrelated public types. More concise index resolution and domain-redeemer conversion are **planned in the Haskell ergonomics pass**, not native API omissions. |
| T06 Staking, pools, DRep/committee, votes, proposals and donation | A1; C1 and governance modules; S1 staking helpers | Certificate, Pool, Governance, Plan certificate/withdraw/vote/propose/donate; test/Certificates.hs, test/Pool.hs, test/Governance.hs, test/Proposals.hs, test/DijkstraBuilder.hs | **Implemented** native typed construction/building. Querying current governance state is P03/P04 below. The construction completion slice adds currentTreasuryValue and explicit/deferred proposing redeemers through shared native builder extensions; see TRANSACTION_CONSTRUCTION.md for tests. |
| T07 Compiled-code/ledger-type interoperability | S10; A6/A7; cardano-api Plutus/Ledger exports | PlutusData explicit ADT and Script.Plutus serialized bytes/applyParams; test/PlutusData.hs, test/Scripts.hs | **Partial.** Opaque serialized-script import works. No optional conversions for PlutusTx.CompiledCode, ledger Value/Address/Tx types or cardano-api types. S10 also applies arbitrary supported UPLC builtin constants; Cometa applyParams takes PlutusData values, so direct non-Data builtin parameter application is not equivalent. This is a Haskell interoperability layer, not exposure of private C UPLC structs. |
| T08 Typed datum/redeemer codecs and blueprints | S7/S8/S10; A8 | Explicit PlutusData assembly and script parameter application | **Missing / deferred ergonomics.** No ToData/FromData deriving, CIP-57/Aiken blueprint reader, schema validation, generated Haskell types or validator-role lookup (including S8 CIP-143 helpers). Raw script bytes do not implement blueprint parsing. |
| T09 Script compiler/UPLC tooling | S7 program conversion; A7 applyParam uses UPLC; compiler dependencies in upstream manifests | Compiled script byte import, hash, native applyParams | **Partial.** No public program-level UPLC AST/parser conversion or general builtin-constant application comparable to S7/S10. Existing cardano-c installed UPLC surface exposes Data parameter application, not private VM internals. These upstream modules consume compiled code; they do not themselves provide an Aiken compiler service. A standalone compiler/optimizer service would be additional scope, not an inferred missing export. |
| T10 Exact transaction/body identity, witnesses and external signing | C1/C4 and Tx signing APIs; A9/S9 | Transaction/SubTransaction encode/decode, Signing, Witnesses, Signer records, scoped Software handlers; test/PublicTransaction.hs, test/TransactionWitnesses.hs, test/SoftwareKeyHandler.hs | **Implemented** explicit partial signing/merge and exact imported CBOR preservation. Builder rebuilds return a new unsigned transaction; they do not silently preserve old signatures. Bootstrap witness values are representable; automatic historical Byron wallet signing is not established (K04). |
| T11 JSON inspection and interchange | S11; cardano-api Serialise.Json/TextEnvelope; Atlas type instances | Transaction.Inspection full/body/sub JSON; test/TransactionInspection.hs | **Partial.** CIP-116 inspection is implemented and must not be advertised as an inverse transaction codec. Upstream typed JSON/text-envelope file import/export, native-script JSON and metadata JSON schemas are not a general public API. |
| T12 Address-level balance changes and wallet summaries | S2 balanceChanges; A6 value algebra | Building.imbalance reports aggregate conservation; Value quantities | **Partial.** Aggregate transaction imbalance is not the per-address input/output delta returned by sc-tools. A pure helper can supply that accounting without a native extension. |
| T13 Chained/parallel transaction planning | A1 buildTxBodyParallel/buildTxBodyChaining | Individual Builder.build and ordinary IO composition | **Missing** a tracked dependency/funding orchestration API and equivalent failure/result semantics. Dijkstra atomic batching is a different capability. Parallel calls to independent builders do not implement chained transaction selection. |

## Dijkstra comparison: current upstream already has support

The current cardano-api snapshot explicitly exports DijkstraEra,
SubTxBodyContent, makeUnsignedSubTx, signSubTx, setTxSignedSubTransactions,
TxGuards, direct deposits and account intervals (C3–C5). Its package depends on
cardano-ledger-dijkstra. Therefore **“Cometa supports Dijkstra ahead of upstream
Haskell” is not a valid blanket claim**.

The reviewed Atlas/sc-tools snapshots do not expose those Dijkstra transaction
surfaces. Cometa has a concrete Dijkstra capability beyond those snapshots, while
current experimental cardano-api overlaps substantially. This is source API
comparison, not proof that the two ledger versions accept identical encodings.

| ID / capability | Current cardano-api evidence | Cometa evidence | Comparison boundary |
| --- | --- | --- | --- |
| D01 Independent subtransaction creation, IDs and signatures | C4 makeUnsignedSubTx/getSignedSubTxId/makeSubTxKeyWitness/signSubTx | SubTransaction.Body/Builder/Plan and Signing/Software sub signing; test/SubTransactionBuilder.hs, test/SoftwareKeyHandler.hs | **Implemented** native semantics. Cross-library golden interoperability at these exact revisions remains untested; do not infer it from shared names. |
| D02 Ordered key/native/Plutus guards and witness indices | C5 mkTxGuards/traverseTxGuardsExecutionUnits; C3 | requireGuard/guardWithRedeemer, native evaluation/indices; test/DijkstraBuilder.hs, test/NativeEvaluation.hs | **Implemented** explicit native-supported guard workflows. Compare insertion order, duplicate rejection, referenced-script hash checks and guard redeemer indexing before claiming identical contracts to C5. |
| D03 Attach already signed subtransactions and balance an outer transaction | C4 setTxSignedSubTransactions; C3 | Plan.attachSubTransaction, resolved inputs, witness/byte preservation; test/DijkstraBuilder.hs | **Implemented** native batching. Atlas-style sequential transaction chaining T13 is not a substitute or an equivalent. |
| D04 Direct deposits and exact/range/starting account balances | C3 top/sub fields and setters | top/sub Plan.directDeposit/accountBalance, top startingAccountBalance; typed Fields; test/DijkstraBuilder.hs, test/TransactionBody.hs | **Implemented** native serialization/building. Provider account-state discovery and network readiness are separate requirements, not implied by offline fixtures. |
| D05 Per-level evaluation, limits and complete signer discovery | C3/C15 experimental evaluation/witness estimation | Evaluation.Target and native full enclosing context; top Authority.requiredKeyHashes; test/NativeEvaluation.hs, test/ContextualTransaction.hs | **Partial.** Public authority utility intentionally discovers directly required top-level keys only; no full native-script alternative signer solver or subtransaction authority utility. Native global VM ceiling is fixed; trace/ceiling customization needs new public native support. |

## Providers, state and infrastructure

| ID / capability | Primary source evidence | Cometa evidence | Status and missing workflow |
| --- | --- | --- | --- |
| P01 Address UTxOs, supplied input resolution, datums, protocol parameters, rewards, submit and confirmation | S3; A4 | Provider record plus optional Provider.Blockfrost; test/Provider.hs; blockfrost-test/BlockfrostProvider.hs, BlockfrostHttp.hs, BlockfrostProtocol.hs | **Implemented** corresponding record operations and HTTP adapter, including custom endpoints/optional project ID. Confirmation polling is not rollback-aware finality, and separate HTTP queries are not an atomic ledger snapshot. HTTP rejection errors expose operation/status, not structured ledger diagnostics; that error-detail capability remains partial. |
| P02 Payment-credential, multi-address, asset-index and historical queries | S3 MonadUtxoQuery; A2/A4 GYQueryUTxO | utxosAt, utxosWithAsset at one address, utxoWithAsset single-result and current unspent resolution | **Partial.** No bulk credential query, complete global asset UTxO listing, historical transaction retrieval or indexed spent-output history. Calling single-result utxoWithAsset is not equivalent to listing all outputs carrying an asset. |
| P03 Governance state, constitution/proposals, DRep state and delegation queries | A2 govState/drepState/proposals/constitution; S3 queryStakeVoteDelegatees; C6 | Typed governance values and provider reward balance | **Missing.** Construction and reward amount do not answer these state queries. Extend provider contracts/backends and deterministic fixtures; do not invent answers from transaction bodies. |
| P04 Stake pools, stake delegation/deposits, system start, era history and current slot | S3 queryStakeAddresses/queryStakePools/queryEraHistory/querySlotNo; A2/A4; C6 | Explicit protocol snapshot, NetworkId and fixed SlotConfig | **Partial.** No public live era-history/current-tip/pool/delegation query surface; reward balance alone does not supply registration/delegation/deposit state. Static slot arithmetic is not multi-era history interpretation. |
| P05 Wait for slot/block, mempool inspection and pending-spend handling | A2 mempoolTxs/waitUntilSlot; A4; sc-tools node client | awaitTransaction ID polling | **Partial.** Await by ID exists; slot/block waits and provider-backed mempool/pending-spend queries remain missing. Chain rollback services are excluded under P08. |

## Excluded infrastructure (comparison context only)

These entries retain their original IDs and source references for traceability.
They are excluded from the remaining-work and completeness assessment.

| ID | Excluded capability | Source evidence |
| --- | --- | --- |
| P06 | Additional built-in provider backends and service caching/observability integrations | S12; A5 |
| P07 | Local-node/Ouroboros transport, local state-query client and chain synchronization | C7; S3/S4 |
| P08 | Full ledger validation/state transitions, chain indexing and rollback services | C8; S4/S5 |
| P09 | Ledger emulator/mockchain and contract-game infrastructure | S5; A10 |
| P10 | Private-network/devnet creation and node-process orchestration | S6; Atlas Test.Privnet |
| P11 | Standalone CLI, RPC server and WASM/browser applications | C16/C17; S11; cardano-addresses Command |

## Keys, addresses, values and standards

| ID / capability | Primary source evidence | Cometa evidence | Status and concrete limitation |
| --- | --- | --- | --- |
| K01 Scoped Ed25519/BIP32, hashes, signature verification and password storage | D1/D9; A9; C9 | Crypto.Ed25519/Bip32/Blake2b, Software handlers, Emip3/Pbkdf2; test/Ed25519.hs, test/Bip32.hs, test/PasswordCrypto.hs, test/SoftwareKeyHandler.hs | **Implemented** native crypto workflows with explicit scoped secrets. EMIP-3 software storage is not byte-compatible with cardano-addresses EncryptedKey or its passphrase rotation API. |
| K02 Recovery phrases, randomness and dictionary support | D8 and Cardano.Dictionary language modules; C9 generateMnemonic/autocomplete helpers | English Crypto.Bip39 import/export from caller-supplied entropy; test/Bip39.hs | **Intentional boundary; optional dictionary gaps.** Seed/entropy generation is application-owned and is not missing binding functionality. English mnemonic conversion from supplied entropy exists. Multilingual dictionaries and prefix autocomplete are nice to have. |
| K03 Shelley/governance/shared path derivation and discovery | D1/D2/D5; C9 mnemonic-to-role-key | DerivationPath supports custom purpose/coin/roles, 1852/1854 and DRep/committee roles; Bip32 public/private operations; test/DerivationPath.hs | **Partial.** Generic path derivation covers many mechanics, but does not supply sharedWalletId, cosigner-template identity, every style-specific generation contract. A general wallet discovery/synchronization engine is not asserted as an export of these reviewed modules. |
| K04 Legacy Byron, Icarus/hardware and shared wallet schemes | D3/D4/D5 | Complete Byron address values/codecs and generic native BIP32 | **Partial.** Byron address parsing is implemented; legacy random-wallet master generation, encrypted derivation-path recovery, hardware Ledger root-generation variant and scheme-specific wallet operations are not established. They need audited additional algorithms/backend support, not renamed existing functions. |
| K05 Native script AST, hashes, cosigner templates, validation and text language | D6/D7; S1 native script helpers; Atlas SimpleScript | Script.Native AST, serialization/hash and builders; test/Scripts.hs | **Partial.** General native scripts work. Cosigner templates, textual parser/pretty-printer and recommended structural validation are missing. A native script's ability to serialize does not prove satisfiability or establish a signing policy. |
| K06 Address bytes/text, key/script payment/stake, pointers and historical forms | D2/D3/D4; C Address; Atlas Address | General Address sum, Shelley/Reward/Byron codecs/inspection; test/Address.hs, test/CompleteAddress.hs | **Implemented** native-supported address representation. CLI structured diagnostic reports and legacy wallet recovery K04 are not covered. Pointer components follow pinned native Word32 bounds; do not advertise every upstream ChainPointer range without an explicit boundary comparison. |
| K07 Consensus/operator keys and certificates | C9 KesKey/VrfKey/BlsKey; C13 | Pool.Parameters and Pool.BlsKey accept bounded public values; certificates | **Partial.** Public BLS key/proof bytes are representable; no BLS key generation/proof creation, KES/VRF secret operations, operational certificate issuance or genesis key administration. These algorithms are not exposed by existing Ed25519 wrappers. |
| K08 Assets/value algebra and fingerprints | A6; cardano-api Value; S1 | AssetId codecs/fingerprint, PolicyId/AssetName, arbitrary signed Integer Value; test/AssetId.hs, test/Value.hs | **Partial.** Core construction/sum/difference/scale/inspection works. Atlas' valueMonus, splitSign, map/alter/restrict/intersection helpers and typed upstream conversions are not all named public operations. Several are implementable purely from toList/fromList/quantity; composability is not identical convenience API coverage. Standalone checked Value/mint CBOR and signed value helpers are now provided; broader general JSON interchange is optional. |
| K09 Governance identifier text and serialization envelopes | C10/C11; A9; cardano-addresses text prefixes | Raw hash/CBOR values and address text; CIP-116 transaction inspection | **Partial comparison coverage.** DRep CIP-105 import/CIP-129 import/export and checked governance-action text are provided. Committee text and cardano-cli envelopes/file helpers are optional additions absent from this native coverage slice. Action text rejects indices above 255 instead of silently narrowing. |
| K10 Metadata/data JSON and broader CBOR primitives | cardano-api serialization/Plutus APIs; S11; A6 | Exact CBOR metadata/PlutusData, selected primitive Cbor functions | **Partial.** No public equivalent of every metadata/script-data JSON schema or general CBOR null/tag/simple/double/tagged-bignum primitive. Arbitrary Plutus integers work through PlutusData, not the bounded primitive Cbor integer helper. |
| K11 Full era-specific/genesis/leadership/poll domains | C12/C13/C14 and cardano-api LedgerState/Genesis | Current native transaction/governance types, legacy certificates and update fields | **Partial application coverage; infrastructure excluded.** Governance poll metadata/answer helpers remain an application-level gap. Genesis generation, leadership scheduling and historical ledger-transition services are excluded infrastructure; their absence is not a binding release blocker. |
| K12 Raw and COSE message signing | D1 sign/verify; upstream key/signature operations | Crypto.Ed25519 and Message.Cip8; test/Ed25519.hs, test/Cip8.hs | **Implemented** raw signatures and address/key-hash-bound COSE outputs, beyond the raw format in D1. CIP8 accepts nonempty direct payloads with empty AAD and hashed=false; it does not establish that the signing key controls the supplied address. Detached/prehashed/custom-AAD signing and a complete COSE verifier are not supplied or implied. |
| K13 Optics, standard instances and effect/error integration | S14 Convex.CardanoApi.Lenses; A1/A2/A6 class and instance surfaces | Explicit immutable ADTs, qualified functions, Plan composition and ordinary Either/IO records | **Partial / ergonomic difference.** No optional lens/Plutus/cardano-api instance packages or drop-in MonadBlockchain/GYTxMonad interpreters. Existing record injection is a deliberate interface choice, not source compatibility. Add only invariant-preserving adapters; unsafe constructors, partial lookup functions and printable secret instances are not required to imitate upstream. |

## Delivery scope: native coverage and idiomatic transaction construction

The maintainer narrowed the delivery scope on 2026-11-07 to all application-facing
capabilities already offered by cardano-c, complete transaction construction for
its supported eras, and small conveniences that make the Haskell workflows
succinct. The upstream comparison remains useful design evidence, not a mandate
to reproduce other libraries' features.

| Required work | Acceptance |
| --- | --- |
| Complete transaction construction | Cover every supported body/witness field and script purpose at valid transaction levels. Add current-treasury-value and explicit/deferred proposing redeemers to the shared native builders, then expose them in Haskell. Preserve low-level assembly for constructions outside balancing conveniences. |
| Existing native domain coverage | Reconcile every remaining native ledger entry against a public operation, a tested Haskell equivalent, or a specific justified omission. Finish standalone Value CBOR, governance identifier text and other existing domain operations. Do not expose native lifetime or mutable-container plumbing as public API. |
| Small Haskell conveniences | Use composable plans, ordinary values/collections, total assembly after checked input, and one natural error boundary. Add helpers only when complete caller examples demonstrate less ceremony. Include deferred-redeemer helpers for typed references, final-index resolution and explicit domain-data conversion; preserve the existing callback API. |
| Construction and lifecycle evidence | Test supported field combinations, top/sub restrictions, reference scripts, immediate/deferred redeemers, signing, witness merging and cancellation/cleanup. Run adapted upstream properties through native-backed Cometa operations, with independent Haskell/ledger checks and reproducible shrinking. Add minimized C regressions for native bugs; see implementation-plan section 19.7. |
| Usable examples and documentation | The README demonstrates payments, assets, scripts, staking, Conway governance and Dijkstra features with actual APIs, links to full programs, and accurately states validation boundaries. |

Additional provider queries, new standards codecs absent from C, blueprints,
upstream interoperability packages, CIP-8 verification, advanced VM tooling,
transaction-chain orchestration and alternative wallet algorithms are optional
future work, not completion requirements. Seed generation and larger infrastructure
remain explicitly excluded. Existing provider injection, local evaluation, signing
and Blockfrost functionality remain supported.

“All constructions” means those supported by cardano-c's targeted eras, not every
historical or prospective ledger rule. Binding correspondence does not establish
ledger acceptance. Dijkstra network readiness requires live validation on an
appropriate network; offline fixtures do not replace it.

## Reviewed primary source catalog

The links below point to the exact downloaded source revisions. Public
exposed-module manifests were checked to distinguish internal implementation
files re-exported by public facades from unrelated private machinery. Actual
README/example workflows (sc-tools README and Atlas Gift) were read alongside
the exports and implementation, rather than inferring behavior from names.

### input-output-hk/sc-tools

- **S1:** [src/base/lib/Convex/BuildTx.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/base/lib/Convex/BuildTx.hs) — transaction composition, witnesses and late redeemer functions.
- **S2:** [src/coin-selection/lib/Convex/CoinSelection.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/coin-selection/lib/Convex/CoinSelection.hs) — balanceForWallet, balanceChanges and evaluation/balance iteration.
- **S3:** [src/base/lib/Convex/Class.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/base/lib/Convex/Class.hs) — MonadBlockchain, MonadUtxoQuery, MonadDatumQuery and mock state.
- **S4:** [src/node-client/lib/Convex/NodeClient/Fold.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/node-client/lib/Convex/NodeClient/Fold.hs) — pipelined block folds and rollback state history.
- **S5:** [src/mockchain/lib/Convex/MockChain.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/mockchain/lib/Convex/MockChain.hs) — ledger-backed mock-chain interpretation.
- **S6:** [src/devnet/lib/Convex/Devnet/CardanoNode.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/devnet/lib/Convex/Devnet/CardanoNode.hs) — node-process lifecycle and private network genesis/configuration.
- **S7:** [src/base/lib/Convex/Aiken/Blueprint.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/base/lib/Convex/Aiken/Blueprint.hs) — blueprint import and compiled-script conversion.
- **S8:** [src/base/lib/Convex/Aiken/Offchain.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/base/lib/Convex/Aiken/Offchain.hs) — CIP-143 blueprint script roles.
- **S9:** [src/wallet/lib/Convex/Wallet.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/wallet/lib/Convex/Wallet.hs) — wallet key/address/signing and input selection.
- **S10:** [src/base/lib/Convex/PlutusTx.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/base/lib/Convex/PlutusTx.hs) — ToData-oriented data helpers.
- **S11:** [src/tx-mod/lib/Convex/TxMod/Command.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/tx-mod/lib/Convex/TxMod/Command.hs) — transaction download/evaluation/graph CLI.
- **S12:** [src/maestro/lib/Convex/Maestro/MonadBlockchain.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/maestro/lib/Convex/Maestro/MonadBlockchain.hs) — alternative provider interpreter.

### geniusyield/atlas

- **A1:** [src/GeniusYield/TxBuilder/Class.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs) — skeleton composition, strategies, parallel/chained builds and signing/submission.
- **A2:** [src/GeniusYield/TxBuilder/Query/Class.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Query/Class.hs) — UTxO, datum, slot, governance, DRep, mempool and user queries.
- **A3:** [src/GeniusYield/Transaction.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Transaction.hs) — balanced-body loop, minimum UTxO and collateral/witness accounting.
- **A4:** [src/GeniusYield/Types/Providers.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Providers.hs) — provider record, UTxO/datum queries, slot actions and parameter history.
- **A5:** [src/GeniusYield/Providers.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Providers.hs) — provider construction and backend selection.
- **A6:** [src/GeniusYield/Types/Value.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Value.hs) — asset/value algebra, JSON and Plutus/cardano-api conversion.
- **A7:** [src/GeniusYield/Types/Script.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Script.hs) — script import, parameter application and compiler interop.
- **A8:** [src/GeniusYield/Types/Blueprint/TH.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Blueprint/TH.hs) — blueprint-generated types, ToData/FromData and parameter application.
- **A9:** [src/GeniusYield/Types/Key.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Key.hs) — role-indexed key operations and text-envelope files.
- **A10:** [src/GeniusYield/Test/Clb.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Test/Clb.hs) — contract testing interpretation.
- **A11:** [src/GeniusYield/Examples/Gift.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Examples/Gift.hs) — actual create-and-spend validator workflow.
- **A12:** [src/GeniusYield/TxBuilder/User.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/User.hs) — wallet addresses, change and collateral configuration.

### IntersectMBO/cardano-api

- **C1:** [cardano-api/src/Cardano/Api/Tx/Internal/Body.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs) — traditional era-indexed transaction fields and witness indexing.
- **C2:** [cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs) — execution units, auto-balance, fee/minimum UTxO.
- **C3:** [cardano-api/src/Cardano/Api/Experimental/Tx.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Experimental/Tx.hs) — public experimental Dijkstra builders, guards and signed subtransactions.
- **C4:** [cardano-api/src/Cardano/Api/Experimental/Tx/Internal/SubTransaction.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Experimental/Tx/Internal/SubTransaction.hs) — subtransaction creation, independent ID/signature and attachment.
- **C5:** [cardano-api/src/Cardano/Api/Experimental/Tx/Internal/Guard.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Experimental/Tx/Internal/Guard.hs) — ordered guard credentials, witness checks and budget traversal.
- **C6:** [cardano-api/src/Cardano/Api/Query/Internal/Type/QueryInMode.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Query/Internal/Type/QueryInMode.hs) — query GADT including broader ledger/governance state.
- **C7:** [cardano-api/src/Cardano/Api/Network/IPC.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Network/IPC.hs) — actual local-state-query and node submission examples.
- **C8:** [cardano-api/src/Cardano/Api/LedgerState.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/LedgerState.hs) — block/epoch folds, validation and ledger events.
- **C9:** [cardano-api/src/Cardano/Api/Key.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Key.hs) — payment/stake/governance/genesis/Praos/Leios keys and mnemonic helpers.
- **C10:** [cardano-api/src/Cardano/Api/Serialise/TextEnvelope.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Serialise/TextEnvelope.hs) — typed text envelopes and file interchange.
- **C11:** [cardano-api/src/Cardano/Api/Serialise/Cip129.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Serialise/Cip129.hs) — governance identifier text.
- **C12:** [cardano-api/src/Cardano/Api/Genesis.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Genesis.hs) — genesis creation/configuration domain.
- **C13:** [cardano-api/src/Cardano/Api/Certificate/Internal/OperationalCertificate.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Certificate/Internal/OperationalCertificate.hs) — operational certificate issuance.
- **C14:** [cardano-api/src/Cardano/Api/Governance/Internal/Poll.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Governance/Internal/Poll.hs) — poll metadata and answer verification.
- **C15:** [cardano-api/src/Cardano/Api/Experimental/Tx/Internal/Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/src/Cardano/Api/Experimental/Tx/Internal/Fee.hs) — current experimental evaluation and auto-balance implementation.

### IntersectMBO/cardano-addresses

- **D1:** [lib/Cardano/Address/Derivation.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Derivation.hs) — extended keys, derivation schemes, signatures and wallet identity hashing.
- **D2:** [lib/Cardano/Address/Style/Shelley.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Style/Shelley.hs) — CIP-1852/1855, payment/delegation/reward construction and inspection.
- **D3:** [lib/Cardano/Address/Style/Byron.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Style/Byron.hs) — Byron master derivation, encrypted derivation paths and address recovery.
- **D4:** [lib/Cardano/Address/Style/Icarus.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Style/Icarus.hs) — Icarus derivation and hardware Ledger key generation variant.
- **D5:** [lib/Cardano/Address/Style/Shared.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Style/Shared.hs) — CIP-1854 derivation and sharedWalletId.
- **D6:** [lib/Cardano/Address/Script.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Script.hs) — native script templates, cosigners and validation.
- **D7:** [lib/Cardano/Address/Script/Parser.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Script/Parser.hs) — native script textual language.
- **D8:** [lib/Cardano/Mnemonic.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Mnemonic.hs) — typed mnemonic construction and dictionary selection.
- **D9:** [lib/Cardano/Address/Crypto/Wallet/Encrypted.hs](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Crypto/Wallet/Encrypted.hs) — encrypted extended-key representation, passphrase rotation and derivation.

### Additional capability boundary evidence

- **S13:** [src/coin-selection/lib/Convex/UTxOCompatibility.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/coin-selection/lib/Convex/UTxOCompatibility.hs) — explicit Dijkstra/V4 compatibility cases.
- **S14:** [src/optics/lib/Convex/CardanoApi/Lenses.hs](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/optics/lib/Convex/CardanoApi/Lenses.hs) — transaction/value/witness lenses, prisms and isomorphisms.
- **A13:** [src/GeniusYield/Types/Era.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Era.hs) — application ApiEra is ConwayEra.
- **C16:** [cardano-rpc/cardano-rpc.cabal](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-rpc/cardano-rpc.cabal) — RPC package surface and backend dependencies.
- **C17:** [cardano-wasm/cardano-wasm.cabal](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-wasm/cardano-wasm.cabal) — WASM/WASI and TypeScript bridge package surface.

Source repositories retain their own license terms; this audit copies no
implementation or test vectors. Source snapshots were inspected without builds,
node access, keys or live requests. Existing Cometa evidence was read from source;
execution results are recorded separately in the example parity record and CI.
