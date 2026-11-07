# Cometa Haskell binding: design and implementation plan

Status: foundation implementation in progress; domain phases remain planned.
Created: 2026-11-04.
Owner: Angel Castillo / Biglup.
Last updated: 2026-11-04 (repository foundation and native inventory).
Repository: https://github.com/Biglup/cometa.hs.
Cabal package: `cometa` (local development name; no Hackage publication yet).

This file is the persistent handoff for the Haskell binding discussion. Keep it
updated as decisions are made and phases are completed. API names and examples
below are proposals unless explicitly recorded as implemented. The source, tests,
and coverage ledger define the current public interface.

## 1. Objective and requirements

Provide a complete, idiomatic Haskell interface to cardano-c. Applications should
work with Haskell domain values and functions and should never need to allocate,
retain, release, or dispose of C objects during ordinary use.

Scope decision (2026-11-07): larger infrastructure is excluded. Do not plan
local-node/Ouroboros clients, chain synchronization/rollback services, full ledger
validation/emulation, devnet orchestration, additional built-in provider backends,
or associated CLI/RPC/WASM applications. Existing provider injection, Blockfrost
with custom endpoints, application-level query improvements and the native
transaction evaluator remain in scope. Measure completeness against binding and
application APIs; excluded infrastructure is not a release blocker.

Seed/entropy generation is intentionally application-owned. Preserve this security
boundary in cardano-c and its bindings: accept supplied entropy/key material for
validation, conversion and derivation. Automatic seed-generation helpers are not
a missing feature or a release requirement. Existing operational randomness for
salts/nonces is unaffected. CIP-8 verification is a separate nice-to-have proposal;
existing CIP-8 support provides signing.

Agreed requirements:

- Cover every applicable public cardano-c domain type, enum, and operation.
  Adapt presentation to Haskell; do not limit coverage to transaction builders.
- Preserve exact integers, field presence, collection semantics, encodings,
  transaction hashes, signatures, and supported era features.
- Use Haskell values for domain data and marshal when native logic is needed.
- Support all native building capabilities, including custom coin selectors,
  providers, evaluators, deferred redeemers, and key handlers.
- Use the native Plutus evaluator by default. Support replacement without
  requiring Aiken or another external evaluator.
- Expose key derivation, signing, verification, message signing, and external
  signing to the extent supported by the native API.
- Hide manual memory handling, including callback registrations and temporary
  objects. Genuine resources may have idiomatic scoped APIs.
- Provide clear, concise, domain-oriented documentation with runnable examples.
  Use MSDN-style API documentation and the Microsoft Writing Style Guide as
  editorial references; use Haddock conventions for Haskell declarations.
- Publish documentation and a package through the target language's normal
  distribution mechanism, with native binaries where needed.
- Target Linux and macOS x64/ARM64 and Windows x64 initially. Keep architecture
  assumptions out of the implementation and document other platforms honestly.
- Validate behavior against cardano-c, the shared conformance corpus, native
  unit-test cases, and real network integration tests where supported.

The binding author guide is authoritative for shared binding requirements:
[cardano-c BINDINGS.md](https://github.com/Biglup/cardano-c/blob/main/BINDINGS.md).
Cometa.py is a useful structural reference for native API coverage. Cometa.js
illustrates language-owned values and hidden marshaling. Neither defines the
coverage baseline or overrides the C ownership contract.

## 2. Scope boundaries

This project is a library, not a node implementation, smart-contract compiler,
wallet server, or mandatory application framework. It should interoperate with
compiled scripts produced by Plinth, Plutarch, Aiken, and other compilers through
supported script/data encodings.

Do not require cardano-api, cardano-ledger, or Plutus Haskell packages in the core
binding merely to reuse their types. Optional interoperability belongs in a
separate package and must justify its maintenance and dependency cost.

This plan authorizes no new release or live transaction by itself. Before a
future integration run, confirm the intended network, current credentials,
funded test-wallet ownership, and permitted flows. Do not copy credentials or
private keys from conversation history into this plan or repository.

## 3. Findings from the API review

The review covered representative source, examples, and documentation, not a
complete audit of the following libraries. External main branches can change;
record source revisions when implementing any adopted pattern.

| Reference | Pattern to adopt | Boundary for Cometa |
| --- | --- | --- |
| [sc-tools builder](https://github.com/input-output-hk/sc-tools/blob/main/src/base/lib/Convex/BuildTx.hs) | Small domain operations and a writer-like `do` builder | Do not copy its lazy self-reference for final-transaction-dependent witnesses; use explicit deferred callbacks |
| [Atlas transaction API](https://haddock.atlas-app.io/GeniusYield-TxBuilder-Class.html) | Composable transaction requirements and separate building/signing/submission | Avoid a large capability-class hierarchy in the first public API |
| [Atlas providers](https://github.com/geniusyield/atlas/blob/main/src/GeniusYield/Types/Providers.hs) | Records of effectful operations beneath higher-level abstractions | Keep provider, evaluator, selector, and signer injection independent |
| [Kuber builder](https://github.com/dquadrant/kuber/blob/master/src/Cardano/Kuber/Core/TxBuilder.hs) | Ordinary values combined with `Semigroup`/`Monoid` | Define our own conflict and ordering rules; composition is not permission to discard requirements |
| [cardano-api addresses](https://github.com/IntersectMBO/cardano-api/blob/master/cardano-api/src/Cardano/Api/Address.hs) | Role-specific hashes, credentials, explicit conversions, grouped exports | Add type parameters only where they prevent meaningful misuse |
| [Atlas tutorial](https://atlas-app.io/getting-started) | End-to-end guide separated from generated API reference | Start with a payment before introducing script/framework machinery |
| [Atlas testing guide](https://atlas-app.io/getting-started/testing) | Testing as part of application development | Distinguish deterministic fixtures, native execution, emulation, and live network evidence |

Specific review findings:

- sc-tools supports both composable builder values and `MonadBuildTx` operations.
  Its final-body-dependent builder documents nontermination risks from circular
  forcing. Cometa's native deferred-redeemer phase should remain explicit.
- Atlas separates queries, building, signing, and submission through capabilities;
  its underlying provider representation is a record of operations.
- Kuber gives individual fields different merge policies, including a preferred
  change address and a maximum explicit fee. Do not assume `<>` has universally
  obvious transaction semantics.
- cardano-api's role distinctions are valuable. Its era-indexed API serves a
  broader native ledger stack; reproducing every era constraint is not a goal.

## 4. Proposed package and module structure

Start with one public core Cabal package and internal modules. Avoid creating
many packages before dependency boundaries require them.

```text
Cometa
Cometa.Address
Cometa.Assets
Cometa.Crypto
Cometa.Keys
Cometa.Keys.Software
Cometa.MessageSigning
Cometa.Metadata
Cometa.PlutusData
Cometa.Script
Cometa.Certificate
Cometa.Governance
Cometa.ProtocolParameters
Cometa.Transaction
Cometa.Transaction.Body
Cometa.Transaction.Plan
Cometa.Transaction.Builder
Cometa.Transaction.Balancing
Cometa.Transaction.SubTransaction
Cometa.CoinSelection
Cometa.Evaluation
Cometa.Provider
Cometa.Error
Cometa.Internal.FFI.*
Cometa.Internal.Marshal.*
Cometa.Internal.Ownership
Cometa.Internal.Callbacks
```

The names are a starting point; split domains as the native inventory requires.
Expose a curated `Cometa` convenience module and qualified domain modules.
Internal modules are not ordinary public entry points.

Likely optional packages:

- Blockfrost provider: isolates HTTP/TLS dependencies from the core binding.
- cardano-api interoperability: explicit conversions for applications already
  depending on that ecosystem; schedule after the first complete binding.

Use Cabal with explicit dependency bounds and tested GHC versions. Keep native
constants as explicit Haskell definitions, with tests comparing their values
against the pinned C headers. Keep platform-dependent layouts and enum conversion
in small C adapters rather than embedding C headers in Haskell modules. Ownership
still needs manual auditing; adapters must be documented and tested.

## 5. Domain values and native API coverage

Use abstract validated newtypes for addresses, hashes, key roles, quantities,
slots, and script bytes where invariants matter. Use algebraic data types for
credentials, scripts, datums, certificates, governance alternatives, and errors.
Use records where ordinary field access/update preserves the domain contract.

Examples of proposed relationships:

```haskell
data Credential
  = KeyCredential KeyHash
  | ScriptCredential ScriptHash

data Script
  = Native NativeScript
  | Plutus PlutusScript

data PlutusScript
  = PlutusV1 ScriptBytes
  | PlutusV2 ScriptBytes
  | PlutusV3 ScriptBytes
  | PlutusV4 ScriptBytes
```

Decide whether a general `Credential` plus role-specific wrappers or separate
payment/stake credential types gives the clearest API. The key-role distinctions
must not disappear merely because their byte lengths happen to match.

Numeric rules:

- Arbitrary-precision Plutus integers use `Integer`.
- Quantities that can be negative, including mint/burn deltas, remain signed.
- Nonnegative amounts use a validated domain type; validate native upper bounds
  before conversion. A `Natural` alone does not enforce a 64-bit maximum.
- Never route monetary values through `Double`.
- Do not derive an unrestricted `Num` instance for a bounded/validated amount if
  it allows invalid values to bypass its constructor.

Collection rules:

- Use standard collections only when their semantics match the protocol.
- Preserve order and duplicate keys in structures that permit them. In particular,
  do not blindly represent arbitrary Plutus maps as `Data.Map`.
- Preserve absent, null, empty, and zero values when they are distinct.
- Do not derive equality or ordering from pointer identity. Define whether
  equality is semantic or representation-sensitive for each encoding-bearing type.

Create an API ledger with these fields:

```text
C symbol / header / kind / Haskell API / public-or-internal /
ownership / status / tests / omission rationale
```

Inventory headers, types, variants, functions, callbacks, and caller-owned buffer
contracts. Track coverage by symbol, not just by header. Every omission requires
a reason. Reference counting and allocator plumbing normally map to internals;
domain functionality must not be hidden as an excuse for missing coverage.

## 6. Serialization and transaction identity

This is an early design gate, not a late optimization.

Decoding into Haskell fields and rebuilding C objects can discard original CBOR
encodings. That can change body hashes or invalidate signatures even when the
reconstructed values look semantically identical.

Prototype a transaction representation with:

- Immutable Haskell field snapshots for ordinary inspection.
- An internal representation of original encoding for unchanged decoded values
  where identity depends on those bytes.
- Controlled edits that invalidate affected encoding caches and hash results.
- An explicit policy for existing witnesses when a transaction body changes.
- No publicly mutable record that can leave an original-CBOR cache stale.

Public users may create updated transaction values; immutability is Haskell's
normal value model, not a ban on editing. Hash-bearing types may need abstract
constructors and named update functions rather than unrestricted record updates.

Specify separate operations for preserving an original encoding versus explicitly
canonicalizing it, if both are supported. Never silently canonicalize a signed
transaction. Standalone CBOR readers/writers and lower-level domain operations
remain available through idiomatic APIs where required by coverage.

Acceptance: exact round-trip CBOR, exact body bytes, hash/signature stability,
copy-independent edits, witness behavior after edits, malformed/trailing input,
and preserved historical/block layouts must be tested before broad rollout.

## 7. Transaction plans and building

The central high-level abstraction is a pure `TxPlan`: Haskell-owned requirements
for a transaction. Native allocation happens when an operation requires C logic.
A plan is not a balanced transaction and does not imply ledger validity.

```haskell
import qualified Cometa.Transaction.Plan as Plan

paymentPlan :: Utxo -> Address -> Lovelace -> TxPlan
paymentPlan input recipient amount =
  Plan.spend input
    <> Plan.payTo recipient (adaValue amount)
```

Offer a small builder DSL over the same plan, not a second semantic model:

```haskell
import qualified Cometa.Transaction.Builder as Builder
import qualified Cometa.Transaction.Plan as Plan

paymentBatch :: Utxo -> [(Address, Lovelace)] -> TxPlan
paymentBatch input payments =
  Builder.exec $ do
    Builder.add (Plan.spend input)

    forM_ payments $ \(recipient, amount) ->
      Builder.add (Plan.payTo recipient (adaValue amount))
```

Define and property-test composition:

| Requirement | Proposed rule |
| --- | --- |
| Outputs and order-sensitive operations | Preserve declaration order |
| Reference inputs | Deduplicate by identity where allowed |
| Spending inputs | Deduplicate compatible identical requirements; reject incompatible witnesses/data |
| Validity requirements | Intersect bounds; reject an empty interval |
| Mint quantities | Combine only when policy and witness/redeemer requirements are compatible; check bounds |
| Metadata | Reject conflicting values for the same key unless replacement is explicitly requested |
| Change address and execution policy | Prefer placing these in build options; reject conflicting declarations if supported in plans |
| Guards and signer requirements | Preserve credential and scope distinctions; do not reduce script guards to key signers |

Implement a lawful associative composition, potentially by accumulating ordered
requirements and validating later. `mempty` must be an identity. Do not throw
synchronous exceptions from `(<>)` to handle ordinary input conflicts.

Building should expose the complete native options surface: available and required
inputs, selectors, change, collateral, parameters, slot configuration, evaluation,
fee/balancing controls, signing requirements, reference scripts, and supported
advanced transaction fields. Audit the actual headers rather than relying on
this descriptive list.

Keep building, evaluating, signing, attaching witnesses, submitting, and waiting
for confirmation independently callable. Convenience combined operations can be
added without making side effects implicit in `buildTransaction`.

## 8. Extension points and errors

Use records of functions as the initial extension mechanism. Do not require users
to implement a large type-class hierarchy to replace one component.

```haskell
data TransactionEvaluator = TransactionEvaluator
  { evaluateTransaction
      :: EvaluationRequest
      -> IO (Either EvaluationError EvaluationResult)
  }

data CoinSelector = CoinSelector
  { selectCoins
      :: SelectionRequest
      -> IO (Either SelectionError SelectionResult)
  }
```

Request/result types must preserve every field in the corresponding native
contract, including resolved inputs, quantities, execution units, and diagnostics
where present. Do not collapse structured errors to strings.

```haskell
let options =
      defaultBuildOptions
        { coinSelector = randomImprove
        , transactionEvaluator = nativeEvaluator
        }
```

Provider and signer interfaces follow the same approach. Expose native large-first
and random-improve selection, native evaluation, and provider-based evaluation as
separate implementations. Random selection tests require deterministic injected
behavior or explicit inputs; do not assume a seed API exists unless verified.

Error policy:

- Pure Haskell validation returns `Either` with a domain error type.
- Native/effectful operations initially return `IO (Either ... ...)`.
- Applications may compose them with `ExceptT`; document error mapping when
  different operations have different error types.
- Keep native-backed operations in `IO` until a separate purity review justifies
  any exception. Do not hide native allocation/mutation with `unsafePerformIO`.
- Use `Maybe` for legitimate absence, not to discard decoding diagnostics.
- Preserve error codes and useful context, while excluding credentials and secrets.
- Catch callback exceptions at the ABI boundary; preserve the cause for the outer
  operation. Do not indiscriminately turn asynchronous cancellation into an
  ordinary recoverable provider failure.

## 9. Deferred redeemers and Dijkstra

Proposed deferred callback shape:

```haskell
type DeferredRedeemer =
  DraftTransaction -> ResolvedInputs -> Either RedeemerError PlutusData
```

The exact arguments must follow `cardano_deferred_redeemer_fn_t`. Drafts and
resolved inputs are immutable snapshots that remain valid after C releases its
borrowed inputs. The callback is pure and deterministic: no network requests,
randomness, signing prompts, or result-affecting counters.

Top-level balancing can invoke it repeatedly. Subtransaction callbacks use local
indices and the native once-per-build contract. Force callback results enough to
catch exceptions while still inside the bridge; laziness must not defer a failure
until after native cleanup. Returned Plutus data transfers one reference to C on
success; partial outputs are cleaned locally on failure.

Expose subtransaction construction, witnesses, signed batches, guards, direct
account operations, balance intervals, and supported Plutus V4 functionality.
Use the current native inventory to establish the exact set. Do not treat a batch
of nested intents as interchangeable with a list of independent transactions.

Protocol/era support must be explicit in build context and validation. Tests using
synthetic Dijkstra parameters prove serialization/building behavior, not that a
public network currently accepts those transactions.

## 10. Keys and signing

Cover the native crypto and key-management APIs, including BIP39/BIP32, derivation
paths, software key handlers, transaction and subtransaction signing, and CIP-8
message signing where supported by the pinned API. Audit serialization and import/
export operations rather than dropping them from the coverage ledger.

Use opaque secret-bearing resources and scoped acquisition such as
`withKeyHandler`. Public verification keys and hashes may be ordinary immutable
values. Private-key export, if exposed for parity, must be explicit and document
the loss of controlled lifetime once copied into application-managed memory.

A scoped handler must reject use after closing. Evaluate a region parameter or
other lifetime discipline, but do not claim a callback-shaped API alone prevents
handles from escaping. Operations must also retain owners while callbacks run.

External/hardware signing returns witness values without requiring private-key
export. Keep partial signing and witness combination available. Sign the native
transaction/subtransaction body hash required by that operation, not hex text or
the complete envelope. Preserve nested witnesses when adding outer witnesses.

Never derive `Show` for secrets. Do not promise Haskell GC zeroes immutable
ByteString copies. Document password/seed input ownership and explicit export
limitations; use native secure storage where available.

## 11. FFI ownership, callbacks, and concurrency

Implement private raw declarations, marshaling, resource scopes, and callback
bridges separately. Audit each acquired/transferred reference against the current
C implementation and documentation.

Required rules:

1. Constructors normally return an owned reference; some getters do too.
2. Borrowed bytes/strings must be copied or kept alive with a valid immutable owner.
3. Retain is not deep clone. Native reference counts are not atomic.
4. Mark a local ownership obligation released after unref even when C leaves the
   pointer non-null because another owner exists.
5. Provider/key-handler context adoption on success differs from borrowed deferred
   callback contexts; implement these contracts separately.
6. Copy diagnostics before releasing native owners.
7. Release operation-scoped resources deterministically on every exit path.
8. Use finalizers only as a fallback for appropriate persistent resources.

Use `withForeignPtr` for managed pointer access. Typed C unref functions accept a
pointer-to-pointer, so they cannot simply be installed as a unary pointer finalizer.
Evaluate a small C adapter versus a controlled Haskell finalizer, including thread
and callback behavior. Prefer no long-lived native objects for ordinary values.

Callback implementation requirements:

- Root Haskell closures/state using supported stable handles; do not pass movable
  heap addresses to C.
- Keep `StablePtr`, `FunPtr`, native contexts, and error state alive until the last
  possible call, including repeated balancing and cleanup callbacks.
- Use callback-capable `safe` foreign imports for entry points that can re-enter
  Haskell. Treat long-running evaluation appropriately for GHC scheduling.
- Only use `unsafe` imports for audited short non-callback calls; the keyword is
  an FFI execution contract, not a general safety endorsement.
- Use masking/bracketing around ownership transitions. Keep callbacks interruptible
  where safe without freeing state still in use by C.
- Catch exceptions inside callbacks, return the native error, and rethrow/translate
  at the Haskell boundary once the native call has safely unwound.
- Do not mark arbitrary native calls `interruptible` merely to make timeouts work.
- Document cooperative cancellation and any noninterruptible interval. If a worker
  continues after caller cancellation, it retains and eventually releases all state.
- Prevent unsupported reentry into the same mutable native operation.
- Independent builds may run concurrently; do not share mutable native handles or
  error slots across operations without a documented synchronization mechanism.

Consult the [GHC FFI guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/ffi.html)
and [ForeignPtr reference](https://hackage.haskell.org/package/base/docs/Foreign-ForeignPtr.html).

## 12. Coverage groups

Use these groups to organize implementation, not as a substitute for symbol inventory.

| Group | Required coverage |
| --- | --- |
| Foundation | Errors, enums, encodings, buffers, CBOR/JSON, time and slot configuration |
| Crypto and keys | Hashing, signature algorithms exposed by C, BIP32/BIP39, derivation paths, key handlers, message signing |
| Addresses and assets | All address forms, credentials, asset names/IDs, multiasset values and collections |
| Script data | Native/Plutus scripts, script alternatives, metadata, Plutus data, parameter application |
| Staking and governance | Pool parameters, certificates, proposals, votes, governance identifiers and collections |
| Protocol parameters | All supported fields, cost models, execution budgets and validation |
| Transactions | Inputs/outputs, bodies, auxiliary data, witnesses, inspection, signing bytes and serialization |
| Building | Plans, builder DSL, balancing, fee/minimum-ADA/script-data-hash utilities |
| Extension points | Providers, selectors, evaluators, signers, deferred callbacks |
| Dijkstra | Native-supported fields and operations, subtransactions, batches, guards and account operations |
| VM | Applicable public UPLC parsing, execution, costs, diagnostics and utilities; not only builder evaluation |

## 13. Validation strategy

Pin a native revision and matching corpus revision in implementation metadata.
Do not embed a particular RC number in architecture documentation. The review
used native source through commit `8dc0c55f4132fcaa2e7961b6cfbfea96a6d93b5d`;
refresh the baseline at implementation start rather than treating it as a release pin.

### Shared corpus

Use the checked-in [binding corpus](https://github.com/Biglup/cardano-c/tree/main/lib/tests/vectors/bindings/v1)
and its [adapter format](https://github.com/Biglup/cardano-c/blob/main/lib/tests/vectors/bindings/v1/FORMAT.md).
At review time it contains 221 deterministic cases and 8 lifecycle scenarios;
read the pinned manifest instead of hard-coding these counts into acceptance.

Implement a JSON-lines executable adapter using the public Haskell API. Expected
results come from the checked-in corpus, not the binding under test. Exercise
Haskell value reconstruction and marshaling; opaque CBOR forwarding alone is not
adequate coverage.

```sh
python3 /path/to/cardano-c/scripts/check-binding-conformance.py \
  --report conformance.json -- /path/to/cometa-conformance
```

Compare CBOR, body bytes, hashes, deterministic signatures, structural inspection
output, and negative cases. Normalize idiomatic Haskell output only in the test
adapter. Preserve all fields; native inspection uses `guards`, not the old
`required_signers` compatibility name.

### Haskell and native tests

- Port relevant native unit tests; include every mapped operation and enum variant.
- Add properties for composition laws, ordering, integer bounds, conversions,
  round trips, snapshot independence, and serialization-cache invalidation.
- Test unexpected/malformed values, unknown discriminants, trailing bytes, and
  unsupported era features with explicit errors.
- Use deterministic provider/selector/evaluator/signer fakes for builders.
- Force GC between callback registration and invocation to test rooting.
- Exercise callback exceptions, lazy exceptions, output marshaling failures,
  repeated balancing, retry, cancellation, and supported concurrency.
- Measure native live allocations and host callback registrations after warm-up;
  RSS and GC activity alone are not leak evidence.
- Run Valgrind and/or supported sanitizer configurations, accounting explicitly for
  GHC runtime behavior. Do not suppress binding-origin errors as runtime noise.
- Test both static and dynamic native linking on representative supported systems.
- Benchmark build/sign/inspect, large data/maps, VM evaluation, marshaling overhead,
  allocation volume, and startup costs. Optimize only after correctness evidence.

### Provider and network validation

Test Blockfrost requests, pagination, missing results, error mapping, rate limits,
timeouts, malformed responses, and confirmation behavior using controlled fixtures.
Do not retry submission blindly or log project credentials.

Port applicable cardano-c examples as complete Haskell programs. Run payment,
native mint/burn, Plutus mint/burn, validator funding/spending, and applicable
staking/governance examples on an explicitly authorized funded test network.
Record transaction IDs and confirmations. Keep real integration tests separate
from hermetic CI and never infer public-network Dijkstra availability from fixtures.

## 14. Documentation, style, and distribution

Documentation structure:

1. Installation and a complete payment example.
2. Domain values, units, bytes/text, addresses, and assets.
3. Build, evaluate, sign, inspect, submit, and confirm.
4. Scripts, datums, redeemers, reference scripts, and collateral.
5. Governance and Dijkstra features, including direct account operations and
   multiple valid signed subtransactions.
6. Custom providers, selectors, evaluators, and signers.
7. Testing, error handling, concurrency/cancellation, and troubleshooting.
8. Complete generated Haddock reference and migration notes.

For every public declaration document meaning, parameters, units, bounds, return
values, errors, defaults, ordering, and observable behavior. Document internal
ownership contracts separately from ordinary user-facing APIs. Prefer qualified
imports, explicit public signatures, short names within domain modules, and
conventional Haskell naming. Pick one formatter and lint configuration in P01;
copy neighboring conventions rather than inventing a new style per module.

Compile complete examples and documentation snippets in CI. Use doctest where
appropriate for pure examples; effectful flows should be compiled examples or
tested documentation fixtures, not pretend doctests requiring live credentials.
Publish a task guide plus linked Haddock reference, versioned per release.

Package/release decisions to prove early:

- Confirm repository, Hackage/Cabal names and availability.
- Choose a supported GHC range using CI evidence, not a promise to support every GHC.
- Package the Haskell source normally; avoid promising portable precompiled Haskell
  libraries across GHC versions. Native C artifacts have a separate compatibility matrix.
- Decide whether native sources are bundled or a pinned installed cardano-c package
  is discovered. Prove clean installation from an sdist without an implicit Git clone.
- Audit licensing and notices for bundled native code and dependencies.
- Test Windows compiler/runtime compatibility and macOS architecture selection.
- Document static/dynamic selection, library lookup, ABI compatibility and native
  version checks. Avoid silently finding an incompatible system library.
- Determine how prereleases interact with Hackage's numeric version scheme and
  Cabal constraints; do not copy npm's `-rc.1` suffix or assume a `next` tag exists.
  Validate current Hackage policy before choosing a preview publication channel.
- Validate `cabal check`, source distributions, clean consumer builds, docs, and
  final downloaded release artifacts before announcing support.

Reference: [Microsoft Writing Style Guide](https://learn.microsoft.com/en-us/style-guide/welcome/).

## 15. Implementation phases and PR sequence

Each PR includes its tests, Haddock updates, coverage ledger changes, and error/
cleanup cases. Phase boundaries can be split into smaller reviewable PRs without
changing acceptance criteria. No phase is complete merely because its examples run.

| Phase | Scope | Dependencies | Acceptance gate |
| --- | --- | --- | --- |
| P00 | Confirm repository/package names; inventory native API; record architecture decisions and native/corpus pins | None | Every native symbol classified; unresolved decisions listed with owners |
| P01 | Cabal skeleton, style/agent guide, CI, native integration and package discovery | P00 | One tiny consumer builds against native C on the initial platform matrix |
| P02 | ABI declarations, ownership helpers, errors, callback/exception/cancellation prototype | P01 | Owned/borrowed/adopted contracts and forced-GC callback tests pass; no leaked registrations |
| P03 | Encoding/CBOR foundation and transaction encoding-preservation prototype | P02 | Unchanged transaction identity preserved; edits invalidate caches correctly |
| P04 | Crypto, hashes, BIP39/BIP32, secret storage, derivation and software key handling | P02 | Known vectors, invalid inputs, scoped cleanup, export and logging behavior verified |
| P05 | Addresses, credentials, asset/value types and general collections | P03 | Public-value marshaling, exact integers and collection semantics verified |
| P06 | Metadata, Plutus data, native/Plutus scripts and parameter application | P03-P05 | Script/data corpus and parameter application pass; duplicate/order cases preserved |
| P07 | Protocol parameters, pool/staking certificates, governance proposals and votes | P05-P06 | All mapped variants/fields and invalid cases tested |
| P08 | Complete transaction bodies, witnesses, auxiliary data, inspection and signing APIs | P04-P07 | Transaction corpus passes through public values; partial/nested signing covered |
| P09 | Provider/evaluator/selector/signer contracts and native callback adapters | P02, P08 | Deterministic fakes plus failure/cancellation/retention tests for each callback family |
| P10 | Plans, optional builder DSL, native selectors, balancing and standalone utilities | P07-P09 | Deterministic builder recipes and composition properties pass |
| P11 | Native VM/evaluator completeness and deferred redeemers | P06, P09-P10 | Evaluation/error/budget vectors, repeated callbacks and cleanup pass |
| P12 | Full Dijkstra building, subtransactions, signed batching, guards and account operations | P08-P11 | All corresponding native capabilities and fixtures covered; local indices/signatures verified |
| P13 | Blockfrost provider and all applicable native examples in Haskell | P09-P12 | HTTP fixture suite plus authorized live flows with confirmations |
| P14 | Remaining symbol audit, docs completion, performance review and cross-platform hardening | P04-P13 | No unexplained coverage gaps; full conformance/lifecycle suite and CI pass |
| P15 | Release preparation, package/docs publication and artifact validation | P14 | Clean install from published artifacts; compatibility matrix and release notes verified |

Full domain coverage is incremental: P03 is a design prototype, not premature
completion of transaction support. P11 must include public VM functions missed
by an evaluator-only implementation. P14 must reconcile the ledger against the
pinned headers again rather than accepting an old count.

Workflow:

- Keep commits small, Conventional Commit messages, and the maintainer's configured
  signing identity. Do not substitute an agent identity or unsigned commits.
- Open reviewable PRs and inspect actual CI results; fix failures before proceeding
  to the next slice. Passing local tests is not a substitute for CI.
- Stack PRs only if that is the active review arrangement. Do not assume the old
  C++ review sequence is permanent authorization for a new repository workflow.
- Keep implementation tracking out of the user-facing README.
- Follow the local AGENTS.md/style guide and inspect neighboring code before edits.

## 16. Open decisions and required prototypes

| Decision | Proposed direction | Evidence needed before locking it |
| --- | --- | --- |
| Public encoding-bearing types | Abstract values with immutable snapshots and controlled updates | Exact CBOR/body-hash preservation and edit tests |
| Pure versus IO serialization | Keep native operations in IO initially | Any pure facade needs a separate semantic/thread-safety review |
| Builder representation | Ordered Haskell requirements plus validation | Monoid laws, deterministic ordering, conflict diagnostics |
| Effect API | Records of functions; IO/Either boundary | Complete callback payload mapping and ergonomic examples |
| Error structure | Specific domain errors plus an application-level sum | No lost native diagnostics; straightforward ExceptT composition |
| Era typing | Explicit build context first; targeted type-level roles | Show concrete invalid programs prevented without excessive API burden |
| Native finalizers | Scoped cleanup first; minimal adapter where needed | Unary finalizer compatibility, GHC shutdown/thread behavior, no double unref |
| Cancellation | Safe unwind and retained operation state | Cancel during provider/signer callbacks without early free or swallowed cancellation |
| Secret resources | Opaque scoped handler | Escaping-handle behavior, concurrent close/use and secret-copy limitations |
| Provider transport | Optional Haskell HTTP-backed Blockfrost implementation | Cross-platform TLS, dependency footprint, complete provider contract |
| Distribution | Hackage source package plus tested native integration | Clean sdist install, GHC/ABI matrix, prerelease policy |
| Optional interoperability | Separate cardano-api adapter package | Demand and conversion correctness without changing core dependencies |

## 17. Definition of done

- [ ] Haskell naming/style rules, public API review, instance laws and FFI contracts
      satisfy the engineering gates in section 19.
- [ ] Every applicable public native type, variant, and operation has a reviewed mapping.
- [ ] All intentionally internal/excluded entries have explicit reasons.
- [ ] Full pinned corpus passes with no silent skips.
- [ ] Public-value reconstruction, not only raw CBOR forwarding, is tested.
- [ ] Ownership, GC, callback errors, cancellation and concurrency checks pass.
- [ ] Native live allocations and callback registrations return to baseline.
- [ ] Built-in and custom selectors/evaluators/providers/signers are validated.
- [ ] Key handling, partial signing, message signing and nested signing are covered.
- [ ] Dijkstra capabilities are complete relative to the pinned native API.
- [ ] Documentation/examples compile and links resolve.
- [ ] Authorized live examples pass on networks supporting the exercised features.
- [ ] All advertised platform/GHC/linking combinations have CI evidence.
- [ ] Clean consumers install and use the published artifacts.
- [ ] Documentation and release/migration notes are published.
- [ ] Binding links are added to cardano-c and cometa.dev after publication, using
      the existing website card format: GitHub and Documentation only.

## 18. Resume instructions

Apply the engineering standards and reference set in section 19 during P00/P01.

The first foundation was merged in [PR #1](https://github.com/Biglup/cometa.hs/pull/1).
It covers the initial P00/P01 foundation and a small P02/P04 hashing slice. Read `AGENTS.md`, `CODING_CONVENTIONS.md`, the current CI results,
and `native-api.csv` before continuing. The ledger inventories 3,881 declarations
from 231 public headers; presence in that inventory does not mean implemented.
`native/cardano-c.ref` pins the native source and `native-baseline.json` records
header/corpus provenance.

The initial public surface is `Cometa.nativeVersion`, structured errors, and
`Cometa.Crypto.Blake2b` construction, hashing, and byte/hex inspection. Construction
from bytes/hex is pure validation returning `Either`; it does not enter C. Native
operations use `IO (Either Error a)` and return copied Haskell values. This does
not yet establish the callback, secret-resource, or transaction ownership model.
Continue with the remaining ABI/ownership/cancellation prototypes before broad
crypto and encoding coverage. Hackage name availability, native distribution,
callback retention across all native families remains an acceptance gate.

Documentation uses Haddock for API contracts and Sphinx/MyST for the narrative
guide. Read the Docs needs project import; Hackage publication is a release task.
Neither hosted service is advertised as already published.

Local foundation evidence: GHC 9.6.7 builds with warnings as errors; eleven tests
include 200 Hedgehog cases; Ormolu and HLint pass; all three public modules have
complete Haddock coverage; strict Sphinx and link checking pass. A clean extracted
sdist builds against the pinned native library, and the README example compiles
and runs. Full Valgrind checks, including cancellation, pass with zero errors and no lost
allocations using fair thread scheduling and two RTS capabilities. The first foundation passed all six compiler/platform legs and both quality jobs
in [CI run 41775741679](https://github.com/Biglup/cometa.hs/actions/runs/41775741679). No full phase completion or release readiness is implied by these checks.

### P02 ownership and callback work

Merged [PR #2](https://github.com/Biglup/cometa.hs/pull/2) introduces named native error codes and a private `core` Cabal
component. Public Error definitions stay in the main library so its Haddock and
Hackage archives are self-contained. Private native failures retain exact numeric
statuses and map to public errors at the domain boundary.

`withOwnedOutput` installs cleanup before acquisition, releases partial output on
failure/exception/cancellation, and records release even when another owner keeps
the native pointer non-null. Real hash allocations exercise those paths. Borrowed
bytes are copied while their owner remains alive.

The private provider-confirmation adapter exercises an actual native callback.
The C shim owns native structure layout and Boolean conversion. A successful
provider construction adopts the context; final native destruction frees the
StablePtr and dynamic callback pointer. Independent aliases and active operations
hold separate native references. Their non-atomic refcount updates are serialized.
A closed alias is invalid even when another reference keeps the native object alive.

Each operation has fresh error and cancellation state. A native worker and a
scoped handler worker keep cancellation out of the ABI callback thread. Results
are forced before C resumes. Cancellation targets the handler, waits for native
unwind, then rethrows the original exception. Caller masking state is preserved;
a deliberately masked/nonterminating handler or nonreturning native operation can
delay cancellation indefinitely. State and buffers remain alive during that wait.
Same-provider overlap/reentry is rejected; independent providers may overlap.

Tests cover GC, copied payloads, weak-root release, retained aliases, partial
allocation failures, synchronous/lazy exceptions, pre-dispatch cancellation,
cancellation races, delayed masked-handler unwind, and concurrent error isolation.
The 27-test suite and full Valgrind run passed locally before merge. The public provider
API is still deferred to P09. Actual borrowed deferred-redeemer registrations and
deterministic native constructor-allocation failure injection remain unverified;
this prototype does not close those gates or establish P11 balancing behavior.

Update this plan with decisions, PR links, tested revisions, results and remaining
work as implementation proceeds. Keep release-specific pins in implementation
metadata and test provenance, not in the general binding architecture guide.

### P03 encoding and transaction-identity prototype

Merged [PR #3](https://github.com/Biglup/cometa.hs/pull/3) adds `Cometa.Encoding.Cbor`: exact encoded values, hexadecimal
conversion, primitive integer/byte/text/Boolean codecs, and compositional arrays
and ordered maps. Integer codecs cover the complete primitive CBOR integer range;
tagged bignums, floating-point codecs, and the complete streaming reader/writer
surface remain pending in the native API ledger. Encoding identity is bytewise,
not semantic equality. Maps preserve duplicate entries and order.

`Cometa.Internal.Transaction` is an internal design prototype, not public
transaction support. It snapshots the original full/body/witness bytes, body hash,
and fee into Haskell values. Native decoding alone cannot preserve the full outer
encoding: serialization emits a definite envelope. Therefore unchanged values
return the original full bytes, including indefinite and historical layouts.

Fee edits decode and deep-clone native state. The native fee setter does not
invalidate the body's cached encoding; the adapter explicitly clears that cache.
It removes outer vkey/bootstrap signatures while retaining script witnesses,
datums, redeemers, and auxiliary data. An equal-fee update returns the original
snapshot exactly. A changed fee may normalize body/envelope encoding and requires
rebalance, reevaluation, and signing before submission; the prototype does none
of those tasks. Other fields, nested transactions, and the public editing API
remain P08/P12 work.

Tests use imported historical bytes and constructed noncanonical/frame variants,
with independent body-hash/signature provenance in
`test/Fixtures/TRANSACTIONS.md`. The 28 new tests include seven 300-case properties;
together with the earlier foundation, all 55 tests and 2,400 property cases pass
locally with warnings as errors. Full Valgrind reports zero errors and zero lost
allocations without suppressions. The build, CBOR example, Haddock, strict guide,
and native inventory checks pass. All eight hosted CI jobs passed before the next slice began.

Full P03/P08 coverage is not implied: streaming interfaces, JSON/other encodings,
tagged bignum/float construction, public complete transaction fields, broader
mutation laws, and deterministic native allocation-failure injection remain
pending. Text decoding validates UTF-8 per indefinite chunk, while raw CBOR
import preserves native-reader-accepted structures without schema/tag validation.

### P04 first slice: Ed25519 values and scoped signing

This slice covers normal and extended Ed25519 keys, signatures, verification,
public-key hashing, explicit secret export and independent scoped cloning.
BIP32/BIP39, software key handlers, other crypto primitives, and transaction/CIP-8
signing remain later P04 work; generic byte signing does not complete those APIs.

Public keys and signatures are abstract immutable Haskell byte values. Import
validates encoded length; equality/order compare bytes. Native clone semantics
adapt to ordinary immutable value reuse. Verification and public-key hashing use
scoped native calls, and all returned public data is copied before cleanup.

Signing keys have no `Show` or equality instance. Scoped acquisition takes a
callback returning `IO (Either Error a)`, keeping expected acquisition and action
failures in one result channel. Exceptions propagate after cleanup. A private
lock protects each native key through operations and closure; user-supplied bytes
are evaluated and borrowed before taking that lock. No user callback executes
under it. Closed handles reject operations, and clones own independent scopes.

Native secret-storage audit at the pinned revision: final private-key destruction
calls `sodium_memzero` on its key-material buffer, but the allocation is ordinary
heap storage, not locked memory. The normal-signing helper's temporary stack
`sk[64]` is not explicitly wiped on every path. This is a native follow-up, not a
promise the binding can make about erasing all secret copies. Input and exported
Haskell byte/text values remain caller-managed; public documentation describes
that observable lifetime boundary without claiming comprehensive erasure.

The native Boolean verification function also maps initialization failure to
false. The Haskell API therefore promises `Right True` only for successful
verification and `Right False` when it did not succeed; it cannot recover a
separate diagnostic the native interface does not provide.

Validation: all 79 tests pass, including 24 Ed25519 tests and 3,600 property
cases overall. Eight fixed signing vectors include four RFC 8032 cases and
independently checked normal/extended cases; provenance is recorded in
`test/Fixtures/ED25519.md`. Tests cover operation failures, callback errors,
exceptions, cancellation, escaped handles, retained native references, cloning,
concurrent close/sign, and input evaluation before locking. Full Valgrind reports
zero errors and zero lost allocations without suppressions. Compiler probes
confirm that signing keys expose neither `Show` nor `Eq`. The build, example,
guide example, public Haddock, strict Sphinx, formatting/lint, and native inventory
checks pass locally; source-package and hosted CI results are recorded in the PR.

### P04 second slice: BIP32 keys and derivation

This slice adds `Cometa.Crypto.Bip32.PublicKey` and
`Cometa.Crypto.Bip32.PrivateKey`: immutable 64-byte public keys, scoped 96-byte
private keys, byte/hex import/export, raw BIP39-entropy root construction,
ordered soft/hardened derivation, independent clone scopes, and conversion into
existing scoped extended Ed25519 signing keys. Mnemonic parsing, derivation-path
records for key handlers, software key handlers, other crypto primitives and
transaction/CIP-8 signing remain pending; this does not complete P04.

Encoded path indices are `Word32`; the high bit selects hardened derivation.
`harden` is idempotent OR, matching native semantics. Public paths reject the
first hardened index before native work. Empty paths satisfy the identity law:
public value reuse or independent private clone, adapting the native empty-path
error. Imports validate lengths rather than curve/scalar validity. Root entropy
accepts only standard BIP39 sizes (16/20/24/28/32), stricter than the native
arbitrary nonempty input. Passwords are raw bytes without normalization. The KDF
is Cardano PBKDF2-HMAC-SHA512, 4096 iterations, 96 output bytes then scalar clamp;
it does not consume a mnemonic sentence or 64-byte BIP39 seed.

Private operations and closure use the reviewed Ed25519 locked-state protocol.
Application path/input evaluation precedes native use under the source lock;
callbacks run outside locks. Acquisition output slots start at NULL and cleanup
handles partial results, masked publication, aliases retained by native code,
exceptions and cancellation. Ed25519 conversion acquires independently owned
native secret storage directly into its own scope. Public results survive closure.
The final native BIP32 deallocator wipes its secret buffer, but allocations are
ordinary heap storage and the root/derivation stack intermediates are not all
wiped. No comprehensive erasure is promised for native temporaries or host copies.

The BIP32 public hash includes all 64 bytes, including chain code; credential
hashing requires the projected 32-byte Ed25519 public key. All 32 BIP32-header
symbols have explicit mappings/adaptations in `native-api.csv`, including
serialization, reference-count policy and the stricter entropy-size contract.

Validation: all 102 tests pass with warnings as errors, including 23 new BIP32
tests and 900 new property cases (4,500 overall). Tests cover fixed native hardened
and soft derivation vectors, root construction, independent Python PBKDF2/hash
oracles, soft private/public commutation, path concatenation, input bounds,
invalid material, projections, scoped clones, derived/signing independence,
escaped handles, callback failure/exception/cancellation, retained native
references, concurrent derive/close and GC snapshots. Source revision, exact
scenarios, attribution and oracle recipe are in `test/Fixtures/BIP32.md`.
Full Valgrind passed all 102 tests in 52.11 seconds with zero errors, zero lost
allocations and no suppressions. After refining the public representation into a
validated Ed25519 key plus chain code and adding its ordering law, the final
BIP32-only Valgrind run passed all 23 tests in 18.28 seconds with the same clean
result. The existing 120-second CI limit remains unchanged. Deterministic native
allocation-failure injection remains unverified.

The complete build, four examples, Haddock (100% public declaration coverage),
Cabal package check, ClangFormat 18, Ormolu 0.8.0.2, HLint 3.8 and native inventory
checks pass locally. The BIP32 guide example is also extracted and compiled;
strict Sphinx HTML/linkcheck and a source-distribution consumer build pass.
Compiler probes confirm private keys have no `Show`/`Eq`, public constructors are
hidden and shared Ed25519 signing-key representation module cannot be imported by consumers.
Hosted CI for this slice remains to be reviewed in its pull request.

### P04 third slice: English BIP39 mnemonics

This slice adds `Cometa.Crypto.Bip39`: opaque validated English mnemonics,
supplied-entropy conversion, phrase/word-list parsing, word-count inspection and
explicit secret text/entropy export. Software key handlers, derivation-path
records, other crypto primitives and transaction/CIP-8 signing remain later P04
work. No random generation or BIP39 sentence/passphrase seed KDF is invented:
the pinned BIP39 header exposes only the two entropy/word conversion operations.
Exported entropy composes with Cardano BIP32 `withEntropy`, whose root KDF remains
distinct from the 64-byte BIP39 seed KDF.

Mnemonics are ordinary Haskell secret values with hidden constructors and no
`Show` or equality instance. Text parsing splits Unicode whitespace; export uses
single ASCII spaces. Words must be exact lowercase English dictionary entries.
No case folding, spelling correction, other language dictionary or normalization
is applied to words. Count, lexical-position, dictionary and checksum failures
have explicit constructors without supplied words. Native unknown-word status
has no position, so `UnknownBip39Word` deliberately carries none. `Text` inputs
cannot contain invalid UTF-8 byte sequences; non-ASCII/replacement characters
are rejected rather than introducing an unnecessary byte-text API.

Native audit: word outputs borrow static dictionary strings and are copied;
no native owner is acquired by either conversion. Input buffers/arrays live
through each safe foreign call. Output sizes are initialized and checked;
word slots start at NULL. The native checksum failure writes entropy before
returning failure: the wrapper never exports it and wipes its 32-byte scratch
on every exit, including cancellation after foreign unwind. Checksum validation
makes no hidden host entropy copy. The wipe uses public `cardano_memzero`, not a
vendored dependency symbol. Its scoped adaptation is tracked separately in the
ledger. No allocation/retention-failure injection applies to these owner-free
native functions. Native stack intermediates are not wiped, and no comprehensive
erasure guarantee is made for native temporaries or ordinary host secret copies.

Validation: all 115 tests pass with warnings as errors, including 13 BIP39 tests
and 300 new Hedgehog roundtrip cases (4,800 property cases overall). All 24 native
entropy/phrase vectors were crosschecked against independently pinned Trezor
vectors; two independent Python SHA256/checksum cases add 20/28-byte coverage.
Exact source revisions, generation recipe, native attribution and Trezor MIT
notice are retained in `test/Fixtures/BIP39.md` and its companion license.
Tests cover every standard size, invalid counts/lengths, dictionary/checksum,
NUL/case/non-ASCII/word separators, normalized whitespace, wipe extent, GC,
repeated success/failure, cancellation and scoped BIP32 root integration.
Full Valgrind passes all 115 tests in 57.19 seconds with zero errors, zero lost
allocations and no suppressions. Compiler probes reject `Show`, `Eq` and direct
mnemonic construction. No new compiler/platform matrix is claimed.

The complete build, five examples, extracted BIP39 guide example, Haddock (100%
public BIP39 coverage), Cabal check, source-distribution consumer build, strict
Sphinx HTML/linkcheck, ClangFormat 18, Ormolu 0.8.0.2, HLint 3.8 and native inventory
checks pass locally. The optional `ExceptT` example prints only a public key and
exits unsuccessfully on error; it uses a public deterministic test phrase.
Hosted CI remains to be reviewed in the new pull request.

### BIP39 purity spike

Reviewed 2026-11-04 after the initial P04 mnemonic slice. The experiment below
led to the production native-backed pure boundary documented in the next section.
Two isolated prototypes were built against the same native pin and public fixtures;
neither prototype nor an additional cryptographic dependency is part of the package.

| Approach | Evidence | Ongoing cost |
| --- | --- | --- |
| Initial explicit `IO` | Original 115-test suite and Valgrind pass | Correct, but deterministic mnemonic conversion remains effectful to callers |
| Audited pure facade over cardano-c | 26 vectors, exact error parity, GC, concurrent/shared-thunk evaluation and cancellation smoke checks pass | Small private unsafe boundary; native dependency changes require a fresh purity review |
| Pure Haskell conversion | 26 vectors and 1,280 varied cases agree with native and an independent Python SHA256 oracle | Own the conversion algorithm and dictionary, plus a hash dependency |

The experiment recommended the native-backed pure facade. It preserves one
BIP39 implementation and dictionary while allowing ordinary `Either` composition.
This recommendation is specific to the audited BIP39 functions; it does not
justify hiding arbitrary native calls, key scopes, callbacks or providers in
pure functions.

Adopted minimal API, preserving the words-only representation and error reporting:

```haskell
fromEntropy :: ByteString -> Either Error Mnemonic
fromText :: Text -> Either Error Mnemonic
fromWords :: [Text] -> Either Error Mnemonic
exportEntropy :: Mnemonic -> Either Error ByteString
```

`exportText` and `wordCount` are already pure. Keeping `Either` on entropy export
preserves unexpected native/contract failures without a partial getter. A total
`exportEntropy :: Mnemonic -> ByteString` would be a separate representation
choice: cache validated entropy alongside words, retaining another secret value,
or store a representation that supports total pure decoding. The native spike
keeps the words-only representation. The pure Haskell spike stores both words
and entropy and therefore demonstrates a total accessor with that retention cost.

Native audit at the pinned revision: both conversions use bounded stack scratch,
static English strings, byte/string operations and the bundled SHA256 routine.
There is no logger, configured allocator, RNG, callback, reference counting,
initialization dependency or mutable error state on this path. The selected
SHA256 implementation uses local state and constant tables and always returns
success. The wordlist pointer slots are translation-unit-private and never
modified. Existing wrappers copy outputs before buffers expire and wipe entropy
scratch even after checksum failure. Expected errors remain values; cancellation
propagates after safe foreign unwind and cleanup.

The prototype uses concrete `NOINLINE` entry points, `unsafePerformIO`, and local
`-fno-cse`/`-fno-full-laziness` safeguards. Success and failure results are forced
before returning; it does not use `unsafeDupablePerformIO`, lazy foreign reads,
or a public arbitrary-IO runner. See the [base unsafe-IO contract](https://hackage-content.haskell.org/package/base-4.18.3.0/docs/System-IO-Unsafe.html).
These safeguards alone are not a purity proof: independence from external state
and absence of observable effects are the essential requirements. Production
code should force the internal words directly; the temporary facade forces via
`exportText`, which creates an avoidable transient phrase copy.

The pure Haskell prototype adds 113 lines of conversion logic and a formatted
28 KB dictionary module (13,116 bytes of canonical wordlist data). All 2,048 words
match the pinned Trezor English dictionary. Direct additions are `SHA-1.6.4.4`
and `containers`; the SHA package also uses `array`, `binary`, `base` and
`bytestring`. The selected SHA source was inspected: its hashing algorithm is
Haskell arithmetic, with no foreign imports or C sources. A standalone consumer
builds without cardano-c. This establishes feasibility, not endorsement of that
hash dependency or a maintenance audit of it. Duplication of protocol logic and
wordlist provenance remains a cost even with conformance tests.

Experiment coverage is GHC 9.6.7 on Linux x86-64. The native facade was tested
with `-O2` and `-N4`: 26 fixtures, invalid-input error parity, 100 varied-input GC
round trips, eight workers running ten fixture rounds each, shared-thunk
forcing, and cancellation followed by reuse. Cancellation is a smoke test; it
does not prove an exception arrived during the short C call. The Haskell
prototype additionally passed 1,280 cases spanning all five entropy sizes,
validation precedence/whitespace checks, and formatting/lint checks. No timing
benchmark was performed. Neither approach guarantees comprehensive erasure of
host secrets or native stack temporaries.

The optimized native spike also ran under Valgrind. Functional checks passed,
but Valgrind reported 16 bytes in four definitely-lost blocks from GHC's
`initCapabilityIOManager` startup path. A standalone `main = pure ()` executable
built with the same GHC/options and `-N4`, without Cometa or cardano-c, reproduced
the identical allocation stack and counts. This is a runtime baseline finding,
not evidence of a BIP39 allocation leak; the spike must not be described as a
zero-error Valgrind run. A full-spike `-N1` rerun reported zero errors and lost
blocks, as did a runtime-only concurrency control. An earlier `-N1` run reported
an unreproduced 288-byte possible loss without its allocation stack captured;
that observation remains unclassified. No suppressions were used.

### Production BIP39 pure boundary

Adopted 2026-11-04 following explicit maintainer approval. Public `fromEntropy`,
`fromText`, `fromWords` and `exportEntropy` now return pure `Either` values;
`wordCount` and `exportText` are unchanged. `Mnemonic` remains words-only, opaque
and without `Show`/`Eq`. Native and contract failures remain explicit, including
on entropy export. No hidden retained entropy, partial getter or new crypto/hash
dependency is introduced.

`Cometa.Internal.Bip39Pure` is a private implementation module with three concrete
monomorphic `NOINLINE` unsafe boundaries and local optimizer safeguards. It
forces complete word lists directly, copied entropy and public error payloads
before returning from IO; lower marshaling scopes also force decoded/copied
outputs. It creates no extra phrase just to force evaluation. The sole purity
exception and source/build/platform re-audit obligations are documented in
[BIP39_PURITY.md](BIP39_PURITY.md), the conventions and repository instructions.
The native API ledger records the pure public adaptation. The example and guide
use ordinary `Either` composition lifted with `except` into the scoped key flow.

Regression coverage is 116 tests, including 14 BIP39 tests and 300 BIP39 property
cases (4,800 property cases overall). Optimized GHC 9.6.7 Linux x86-64 `-O2`/`-N4`
passes the full suite. New cases force independent varied inputs, perform GC
between conversion/export, repeat distinct native failures, contend concurrently
on a shared result, and cancel repeated evaluation before fresh later conversion.
Cancellation remains a smoke test, with no claim of guaranteed interruption
inside these brief foreign calls. Sharing can extend secret retention; erasure
and evaluation-count guarantees are not added.

The existing compiler matrix is GHC 9.6.7 across Linux x86-64/ARM, macOS ARM/Intel
and Windows, plus GHC 9.10.3 on Linux x86-64. The boundary uses base's existing
monomorphic unsafe-IO/NOINLINE optimizer controls supported across those compilers;
no new GHC feature or dependency bound is required. Each matrix job now additionally
runs the BIP39 group at `-O2`/`-N2`. Native platform branches were source-reviewed
in the audit; only local Linux x86-64 execution has completed at this point.
Hosted matrix results must still be reviewed before claiming cross-platform
validation of this change.

Local production checks pass: warnings-as-errors optimized build, all five
examples, extracted guide example compiled at `-O2 -Wall -Werror`, Haddock all
(100% BIP39 coverage), Cabal check, strict Sphinx HTML/linkcheck, Ormolu 0.8.0.2,
HLint 3.8 (no hints), ClangFormat 18 and native inventory. Full optimized-suite
Valgrind at both `-N1` and the existing CI `-N2` configuration passes all 116
tests (55.96s and 58.33s) with zero errors, zero definite/indirect/possible losses,
and no suppressions. A targeted optimized BIP39 `-N2` run also passes. The historical spike's independently
reproduced `-N4` RTS startup finding and unclassified transient possible loss
remain recorded above; this passing production run does not erase those findings.

## 19. Haskell engineering standards and reference libraries

Added 2026-11-04 following the request for a professional, idiomatic Haskell
library. These are implementation/review requirements, not a claim that an
unimplemented binding has already achieved them. Treat elegance as composability,
clear contracts, lawful abstractions, and predictable behavior. There is no
objective ranking of the "most purist" Haskell library, nor a single universal
style guide. The references below were selected for specific demonstrated designs,
not as a popularity ranking or blanket endorsement of every API they expose.

### 19.1 Reference set

| Reference | Specific lesson | Application to Cometa |
| --- | --- | --- |
| [containers: Data.Map.Strict](https://hackage-content.haskell.org/package/containers-0.7/docs/Data-Map-Strict.html) | Qualified module vocabulary; grouped operations; explicit ordering, bias, strictness and complexity | Small coherent domain modules; document plan composition and collection behavior precisely |
| [text: Data.Text](https://hackage-content.haskell.org/package/text-2.0.2/docs/Data-Text.html) | Abstract types and clear text representation boundaries | Text for human-readable input, ByteString for bytes; explicit decoding and validation |
| [async](https://hackage-content.haskell.org/package/async-2.2.4/docs/Control-Concurrent-Async.html) | Lexically scoped concurrency, propagated exceptions, cleanup under failure | Provider workers belong to operation scopes; cancellation must not orphan native work |
| [Hasql](https://nikita-volkov.github.io/hasql/) | Explicit errors, focused modules, composable operations and optional extensions | Small core API; replaceable execution components; avoid one mandatory application framework |
| [Megaparsec](https://github.com/mrkkrp/megaparsec) | Structured extensible errors, combinators, tutorials and reference documentation | Preserve decoding context; separate machine-readable errors from pretty rendering |
| [optics](https://github.com/well-typed/optics) | Abstract interfaces to composable access/update operations | Consider an optional optics layer only after lawful, invariant-preserving updates are established |
| [Hedgehog](https://github.com/hedgehogqa/haskell-hedgehog) | Integrated shrinking, invariant-aware generators and state-machine testing | Law tests, FFI lifecycle state machines, saved minimal regression cases |
| [Kowainik naming guide](https://kowainik.github.io/posts/naming-conventions) | Established Haskell vocabulary and suffix conventions | Use as a naming reference; document the narrower choices adopted by this project |
| [Google Haskell style guide](https://github.com/google/styleguide/blob/gh-pages/haskellguide.md) | Explicit engineering/style guidance for a substantial Haskell codebase | Review signatures, imports, modules and readability; do not treat company-specific choices as universal rules |
| [Haskell PVP](https://pvp.haskell.org/) | Version and dependency-bound compatibility policy | Version the Haskell API using PVP, with native version/ABI tracked separately |

Sources are representative snapshots; read the selected versions' contracts at
implementation time. Existing libraries may retain partial functions or historical
compatibility decisions that are inappropriate for new Cometa APIs.

### 19.2 Naming and module policy

Adopt these conventions in the repository's coding guide during P01:

- Module/type/class/data-constructor names use UpperCamelCase; functions, fields,
  and ordinary variables use lowerCamelCase. Module files follow their hierarchy.
- Prefer `Cometa.Address`, `Cometa.Transaction.Plan`, and qualified imports such as
  `Address`, `Tx`, and `Plan`. Avoid repeating `cometa` or C prefixes in every name.
- Use `fromBytes`/`toBytes`, `fromText`/`toText`, and `decodeCbor`/`encodeCbor`
  consistently. These names do not imply purity; the signature states effects.
- Use `mkLovelace` for validated construction from a general integer, for example;
  do not make smart constructors partial just to shorten call sites.
- Use `with...` for a scoped resource, `run...` for interpreting an action, and
  `eval...`/`exec...` only when their distinction follows a familiar runner contract.
- Use descriptive observers such as `fee` or `networkId` in qualified modules;
  do not mechanically translate every C getter/setter into `getX`/`setX` methods.
- Use `_` variants only for discarding a result. Use apostrophes for a clearly
  documented variant, normally strictness; do not encode unrelated error policies
  in unexplained primes. Use `By`/`On` when supplying comparison/projection behavior.
- Reuse established operators such as `<>`, `<$>`, and `>>=` through lawful
  instances. Start without custom symbolic operators; require a concrete
  readability benefit, fixity documentation, and a named equivalent before adding one.
- Prefer complete domain names over unexplained abbreviations; keep familiar
  names such as `TxId`, `Utxo`, `Cbor` consistent across modules and docs. Constants
  remain ordinary lowerCamelCase Haskell bindings, not C-style ALL_CAPS.
- Record selectors use domain prefixes when exported unqualified and ambiguity
  would result. Decide any DuplicateRecordFields/OverloadedRecordDot policy once,
  against the supported compiler range; do not mix record styles per module.
- Private FFI declarations may retain recognizable C symbol names with an internal
  prefix for auditability. They must not dictate public Haskell vocabulary.

### 19.3 Types, laws, and totality

- Prefer algebraic data types, validated newtypes, and explicit errors over Boolean
  flag combinations and loosely related optional fields.
- Keep constructors hidden when they enforce lengths, bounds, encoding caches, or
  secret ownership. Do not export an unrestricted record update that bypasses them.
- Audit every derived instance. `Read`, `IsString`, `Num`, `Generic`, `Data`, or a
  public representation conversion must not provide an unintended route around
  validation. Not all of these instances are inherently wrong; each needs justification.
- Never derive printable secret representations. `Show` is diagnostic output,
  not a wire encoding or stable user-facing format.
- If hashes/keys use phantom role parameters, audit `Coercible` and assign nominal
  roles where needed to prevent payment/stake/script-role confusion. Add compile-fail
  checks for the intended safety boundary. See [GHC roles](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/roles.html).
- Introduce a type class only for a coherent abstraction with meaningful instances
  and laws. Records of functions remain the baseline for runtime configuration.
  Avoid orphan instances; use an owned wrapper for optional interoperability.
- Test Semigroup/Monoid and other advertised laws. Bounded arithmetic that can
  overflow or fail does not automatically form a suitable total monoid.
- Normal public operations must handle invalid external input without `error`,
  `undefined`, `fromJust`, unchecked indexing, or nonexhaustive patterns.
  This is a practical total-API requirement, not a claim to eliminate all Haskell
  bottoms, resource exhaustion, or arbitrary exceptions in user-supplied functions.
- Any genuinely necessary unsafe operation belongs in an explicitly separated
  internal/unsafe surface with documented preconditions and safe alternatives.
- Optional optics must obey their laws and preserve serialization/cache invariants.
  A validating or normalizing update is not automatically a lawful Lens; prefer
  a Prism, traversal, or explicit update function when that expresses its contract.

### 19.4 Purity, strictness, and effects

- Keep composition, inspection of materialized values, and domain validation pure
  wherever practical. Make native calls and resource interaction explicit in IO.
- Purity means referential transparency, not merely omitting IO from a signature.
  Do not wrap arbitrary C calls in unsafePerformIO to create a purist appearance.
- Use Either for expected domain failures and Maybe for absence. Preserve standard
  asynchronous-exception behavior after safely unwinding the foreign boundary.
- Do not require an effects framework, custom Prelude, lens package, or universal
  Cometa monad merely to build a transaction. Optional adapters can serve users of
  ReaderT/ExceptT, mtl, effectful, or other ecosystems later.
- Prefer explicit strictness for accumulators and owned snapshots where deferred
  work would retain memory or move exceptions beyond a cleanup scope. Do not enable
  blanket strictness as a substitute for measuring and documenting evaluation.
- Strict fields and Data.Map.Strict only force particular structures to WHNF;
  nested data and functions may remain lazy. Establish which callback results must
  be forced before returning to C. Never suggest functions can be fully evaluated
  simply by adding NFData to a surrounding record.
- Use structured, bounded concurrency. A timeout ending the caller's wait is not
  proof that C stopped using its buffers or callback context.
- Keep a separate performance budget for marshaling, allocations, startup and VM
  evaluation. Use profiles and benchmarks before adding specialization or unsafe
  optimizations that complicate the API.

### 19.5 Documentation and enforcement

Use the containers documentation as a model for exact behavioral contracts and
Megaparsec/Atlas for task-oriented learning. Generated Haddock should group exports
by construction, inspection, transformation, serialization, and effects where
appropriate. Every module needs an explanation of its domain and a small example.
Public comments describe observable behavior; private FFI documentation describes
ownership and runtime mechanics. Avoid importing implementation commentary into
ordinary usage documentation.

P01 must establish one formatter (evaluate Ormolu/Fourmolu), HLint configuration,
explicit module export lists, public signatures, and a documented language-extension
policy. Use normal Haskell formatting rather than the C++ project's Allman/region
conventions. Keep bindings readable: point-free or heavily polymorphic code is not
inherently preferable to named arguments and straightforward pattern matching.

Enforce through CI and review:

- Format/lint checks, meaningful warnings (including incomplete patterns and record
  updates), and clean builds on the supported GHC matrix.
- Warning-as-error policy for controlled project CI; avoid shipping unconditional
  `-Werror` that breaks consumers merely because their compiler adds warnings.
- Unit, property, state-machine, conformance, allocation and callback tests.
- Haddock build, compiled examples, links and source-distribution consumer checks.
- Dependency bounds validated with supported lower/upper configurations; follow
  PVP for exposed types, functions and instances, not npm/SemVer assumptions.
- API review before bulk implementation: inspect a payment example, script spend,
  custom evaluator, external signer, decoding error, and cancellation example.
- Before the first release, request review from an experienced Haskell library/FFI
  maintainer when available and record the outcome. Automated checks alone do not
  establish idiomatic API quality or prove exception safety.

P00/P01 should turn this section into the new repository's CODING_CONVENTIONS.md
and AGENTS.md instructions. Later implementation must match those files and
neighboring modules. Update conventions when the user resolves a design question.

### 19.6 Workflow and usability review

Design complete caller workflows before primitive coverage. The operational
rules and concrete API checklist are in [CODING_CONVENTIONS.md](../../CODING_CONVENTIONS.md).
Validate external data once; use total composition over validated values and
lawful standard instances/defaults. Keep pure owned values pure subject to the
explicit FFI purity audits, and preserve explicit effects where required.

This repository reserves `mk...` for validation and prefers plain names for
valid-value assembly; this is a local consistency rule, not a universal Haskell
naming law. `mkIndex` validates runtime integers, `minBound :: Index` names the
known first component, and `accountPath`, `standardAccountPath`, and
`derivationPath` assemble typed paths. `accountPrefix` inspects a complete path.
Do not add unchecked constructors, partial convenience functions, `Num`, or `Enum`
to simulate usability.

Public-key derivation should require one public workflow call when the caller
only wants a public key. `Cometa.Crypto.Bip32.deriveAccountPublicKey` and
`derivePublicKey` manage intermediate secret scopes; lower-level private scopes
remain useful for multiple related operations. Encrypted software-handler examples
must teach serialization and reload rather than require handlers for simple
derivation. Compose sequential errors with ordinary `Either` or optional standard
`ExceptT`/`except`, and expose one result at the caller boundary. Do not require
an application framework or introduce an abstraction without a workflow use case.

Review signatures and document meanings/order for same-typed password, entropy,
and storage arguments; use an options record only when its actual use improves
clarity. Compile real examples with explicit imports and logical spacing, and
check failure, scope closure, and cancellation. Use the reference set above for
specific contracts and factual comparisons, not claims of stylistic superiority.

### 19.7 Test reuse follow-up

Record reuse provenance (source commit, path and license/notices) for imported
vectors, tests and generator code. Priority sources beyond the native corpus:

- [cardano-coin-selection tests](https://github.com/cardano-foundation/cardano-coin-selection/tree/main/test): balancing, collateral, token bundles and selection invariants.
- [Atlas skeleton tests](https://github.com/geniusyield/atlas/blob/main/tests/GeniusYield/Test/GYTxSkeleton.hs): composition scenarios adapted to our own rules.
- [sc-tools selection tests](https://github.com/input-output-hk/sc-tools/blob/main/src/coin-selection/test/Spec.hs): multi-address and script transaction scenarios.
- [cardano-api generators](https://github.com/IntersectMBO/cardano-api/tree/master/cardano-api/gen/Test/Gen/Cardano): domain generators and optional independent comparison.
- [Plutus conformance](https://github.com/IntersectMBO/plutus/tree/master/plutus-conformance): evaluator results and budgets with pinned compatible semantics/cost models.

Retain imported QuickCheck properties where practical; prefer Hedgehog for new
properties that benefit from integrated shrinking/state machines. Test selector
invariants, not identical random choices. Save minimized failures as regression
fixtures. Agreement with cardano-c detects binding errors but is not independent
proof of native correctness; use external vectors/oracles where appropriate.

### P04 fourth slice: password derivation and EMIP3 storage

This slice adds `Cometa.Crypto.Pbkdf2.deriveBytes`, explicitly exporting derived
secret bytes from raw password/salt bytes, iteration count and output byte count,
and `Cometa.Crypto.Emip3.encrypt` / `decryptBytes` for password-encrypted storage.
Software key handlers, derivation-path records and transaction/CIP-8 signing
remain later P04 work. No password normalization or application cost default is
invented. EMIP3 retains its native fixed 19162-iteration format and empty AAD.

PBKDF2 has a separately audited concrete pure boundary, documented in
`PBKDF2_PURITY.md`. Its native call graph reaches only caller buffers, stack
HMAC/SHA512 state and constant tables; no native allocation configuration, RNG,
logger, callback or mutable error slot. Haskell heap scratch is bracketed and
wiped before release. The monomorphic boundary forces owned bytes and complete
error payloads, with NOINLINE and local optimizer safeguards. This exception does
not generalize the BIP39 helper or authorize pure EMIP3 operations.

EMIP3 remains in IO for random salt/nonce generation and native allocation.
Public sizes are validated before FFI, including the ChaCha20 counter limit that
would otherwise reach sodium_misuse. Inputs are borrowed without mutation; native
header claims that encryption erases caller inputs are not repeated. Returned
native plaintext is copied only on authentication success and wiped before
unref on success, partial failure, exceptions and cancellation after safe foreign
unwind. The native authentication-failure path authenticates before decrypting
and zeros its output before internal release (vendored libsodium
`crypto_aead/chacha20poly1305/aead_chacha20poly1305.c`). Native PBKDF failure is
unreachable for validated internal fixed salt/key arguments; size/allocation
failures precede plaintext output. Explicit host secret bytes retain ordinary
application-managed lifetime and may be logged/copied by callers; no erasure or
controlled secret-handle lifetime is claimed for them.

Native audit exposed uninitialized process-global RNG/runtime state and
malloc(0)-dependent empty decryption. The pinned dependency fix initializes
EMIP3 and the other direct randombytes caller, enables the vendored POSIX
initialization lock on native Unix, validates null/overflow/counter limits, and
allocates one byte of capacity for authenticated empty plaintext. PBKDF2 now
rejects zero iterations and uses a nonwrapping uint32 iteration loop. Full uint32
iterations are accepted by the binding; the upper encoding is tested without
performing billions of HMACs. The exact native revision is `7811fe94dad90f30478ed4b61d96677f188abaa8`.
Cabal propagates pthread when directly linking the native static archive on the
existing Linux/macOS targets; nonthreaded example and source-distribution
consumer links are verified.

Tests use a pinned native PBKDF known answer and EMIP decrypt vector plus an
independent Python hashlib / cryptography binary multi-block derivation and
EMIP3 envelope. Recipes, source paths and licenses are recorded in
`test/Fixtures/PASSWORD_CRYPTO.md`. Tests cover parameter bounds, NUL bytes,
empty passwords, prefix properties across SHA512 blocks, all envelope regions,
wrong passwords, roundtrips, copied plaintext GC survival, observed native wipe
through a retained test-only alias, partial failure, copy exceptions and
cancellation. Shared PBKDF evaluation and cancellation/reuse exercise the pure
boundary. Cancellation is a scheduling smoke test, not evidence that an
exception arrived at a particular native instruction. CI adds an optimized
PBKDF2 group with two capabilities and a compiled example that prints only a
recovered byte count. No compiler/platform matrix beyond existing CI is claimed.

Validation: all 132 tests pass against the updated static native archive with
warnings as errors, including 16 password-crypto scenarios and 100 new Hedgehog
prefix cases. Optimized PBKDF2 and BIP39 evaluation/concurrency groups pass
with two capabilities. Full Valgrind passes all 132 tests in 102.61 seconds with zero
errors and zero definite, indirect or possible losses, without suppressions.
The full build, six examples, exactly matching compiled password-guide example,
Haddock (100% new public module coverage), Cabal check, source-distribution
consumer build, strict Sphinx HTML/linkcheck, ClangFormat 18, Ormolu 0.8.0.2,
HLint 3.8 and native inventory checks pass locally. Hosted CI results remain to
be reviewed; no new compiler/platform execution coverage is claimed.


### P04 fifth slice: validated wallet derivation paths

`Cometa.Crypto.DerivationPath` provides pure abstract `Index`, `AccountPath`, and
`DerivationPath` values, inspection, and encoded BIP32 index lists.
The same module names all nine pinned constants, including multisignature
purpose and governance roles. Custom purpose, coin type and role numbers remain
representable. Constructors validate arbitrary `Integer` component inputs before
conversion: every raw component is 0..2^31-1. Account encoding sets the hardening
bit for purpose, coin type and account; suffix encoding preserves soft role/index.

Audited native `key_handlers/{derivation_path,account_derivation_path}.h` and
`software_secure_key_handler.c` at revision
`7811fe94dad90f30478ed4b61d96677f188abaa8`. Native storage uses uint64 fields but
its consumers cast to uint32, harden the first three and use role/index directly.
The public values deliberately reject silent truncation, hardened-prefix aliases,
and hardened role/index inputs. This is a safe domain representation, not an ABI
mirror. Constants use explicit Haskell values; no new production FFI or native
resources are needed.

Tests compare all constants with native headers; derive full public keys with
standard, multisignature, all six roles, custom distinct components and maximum
components; and compare account public keys with the actual software-handler
account getter plus a pinned native expected xpub. Public account-suffix
commutation and shrinking encoding/inspection properties cover conversion laws.
Provenance and oracle limitations are in `test/Fixtures/DERIVATION_PATHS.md`.
The compiled `cometa-derivation-paths` example and BIP32 guide teach raw components
and root versus account-relative encoding. Software key handlers, transaction
signing and CIP-8 message signing remain pending; this does not complete P04.

The previous password-crypto hosted Linux/GHC 9.6.7 Valgrind job reached its
120-second limit during PBKDF2 cancellation and exited 124. Its forced-termination
summary reported zero definite/indirect losses and zero errors, with 288 possible
bytes, but cannot establish a normal-exit memory result. The full-suite CI limit
is now 240 seconds, allowing for measured local runtime and added path tests;
no suppressions were added. Hosted rerun results must be reviewed separately.

The consolidated API passes all 138 tests, the warnings-as-errors build,
format/lint checks, Haddock and strict Sphinx HTML locally. Public type and
instance links were inspected after consolidating the path module. The fresh source-distribution consumer builds and passes all 138 tests.
The final binary completes the full Valgrind suite normally in 132.75 seconds:
138 tests pass, with zero errors and zero definite, indirect or possible losses;
no suppressions are used. Hosted quality and documentation checks passed on the
implementation commit; the platform matrix remains in progress.

### P04 sixth slice: scoped software key handlers

`Cometa.KeyHandler.Software` supplies abstract `Handler Bip32` and
`Handler Ed25519` capabilities, construction from BIP39 entropy or a scoped
Ed25519 signing key, encrypted binary serialization/deserialization, diagnostic
name, account extended public-key derivation and Ed25519 public-key recovery.
`LoadedHandler` restores the serialized kind as a typed sum. A nominal parameter
role and hidden constructor prevent coercing an Ed25519 handler into a BIP32
handler; external-client positive and compile-fail checks establish this boundary.
Transaction/subtransaction signing requires typed transaction and witness-set
surfaces and remains later P08/P12 work. Custom key-handler implementation records
and CIP-8 also remain pending; this does not complete P04.

The native prerequisite is pinned to
`7a65f2c7309bbba9e86f6aa73214b003fab88aee` ([native PR #221](https://github.com/Biglup/cardano-c/pull/221)).
That change clears the BIP32 root PBKDF2 stack buffer on success/failure and
replaces the software handler's unchecked 96-byte signing-key scratch with a
bounded, deterministically cleared native allocation. Existing BIP39/PBKDF2 pure
boundaries were re-audited for this pin; that narrow review does not make handler
operations pure or establish comprehensive secret erasure throughout the native
crypto implementation. This Haskell slice makes no native-source changes.

Each handler scope roots its own Haskell callback `FunPtr`: native's password
callback has no context argument. A scoped closure captures its callback control,
not a global router. Native constructors copy/encrypt borrowed entropy or signing
key data; they do not retain the source key. Password and entropy marshaling
scopes end after acquisition, before the application continuation. Native
handlers own one reference until close; the callback wrapper is freed only after
native release and all operation/callback workers have joined. The exported
handle retains closed state after scope exit, without a usable native pointer.
Inputs, callback actions and results are ordinary application-owned Haskell values;
this does not promise to wipe ByteString marshaling copies, arbitrary callback
captures, application copies, registers or crash memory.

One state lock spans each native operation and its output copying. Overlap and
callback reentry fail immediately with `KeyHandlerBusy`; independent handlers can
run concurrently. Public close returns busy during an operation, while scope
cleanup waits for it and closes afterward. The existing audited callback-worker
protocol is reused: the caller's masking state controls the password action,
exceptions are caught before returning to C, cancellation targets the user worker,
and both workers join before the lock or wrapper can be released. A private
password-length exception is translated to a structured error only after native
unwind; other exceptions, including cancellation, rethrow normally. Each operation
starts fresh callback exception state. A callback that masks cancellation or waits
for its own operation can delay cleanup; the public contract documents that limit.

Passwords are binary 1..128 bytes, matching the native callback buffer and signed
length result. The native prerequisite corrects the earlier header prose that
incorrectly described a status return.
Constructor passwords use the same limit so every created handler can be opened
through its callback. BIP32 derivation uses an empty BIP39 password; storage
passwords only encrypt the entropy. Raw account components are validated domain
values marshaled to the by-value native struct by a small C adapter. Owned public
results are copied and released on every exit; serialized native buffers are
copied and then cleared/released. Status diagnostics are static sanitized native
messages; mutable custom-handler diagnostics remain deferred in the ledger.

Storage is the native version-1 binary envelope, not CBOR. Before native
allocation, the binding checks magic/version/kind, canonical encrypted sizes
(76/80/84/88/92 bytes for BIP39 entropy, 92/124 for Ed25519), and exact framing;
Integer accumulation prevents length overflow. Native then checks CRC. Loading
neither invokes the password callback nor authenticates the encrypted payload.
Metadata is CRC-protected, not cryptographically authenticated: an attacker can
rewrite compatible kinds and recompute CRC. The guide states the trusted-storage
requirement. Only a subsequent public-key operation authenticates/decrypts the
inner payload; wrong passwords fail there.

`test/SoftwareKeyHandler.hs` adds 20 scenarios, covering pinned native binary and
public-key vectors, normal/extended signing-key import, all entropy lengths,
maximum account components, deferred password use, storage/CRC/input bounds,
wrong passwords, NUL/128-byte passwords, callback exceptions and invalid length
recovery on the same handler, close/escape, source independence, busy reentry,
concurrency, cancellation finalizer joins, scope-exit joins and independent
callback registrations through GC. Fixture provenance is in
`test/Fixtures/SOFTWARE_KEY_HANDLERS.md`; comparison with the existing BIP32 API
is binding conformance rather than a separate cryptographic oracle. Source
inspection and worker/barrier tests establish callback lifetime ordering; no
native wrapper-allocation counter is claimed. The guide example is compiled as
`cometa-software-key-handler` and prints only a public key.

Local GHC 9.6.7 verification against the new isolated static native archive:
all 158 tests pass, public handler Haddock coverage is 100%, strict Sphinx HTML
build passes, HLint is clean, and external-consumer role/capability checks pass.
The fresh source-distribution consumer builds and passes all 158 tests. Ormolu,
ClangFormat, HLint, Cabal package checks and the compiled guide example pass.
The final binary completes all 158 tests under Valgrind in 177.57 seconds with
zero errors and zero definite, indirect or possible losses, without suppressions.
Hosted quality and documentation checks passed on the implementation commit;
the platform/compiler matrix remains separate and is still running.

### P04 ergonomics follow-up: public derivation workflows

`Index` now has lawful `Bounded` values (0 and 2147483647), while `mkIndex`
continues validating arbitrary integers. Total path assembly uses `accountPath`,
`standardAccountPath` and `derivationPath`; `accountPrefix` is the observer.
`Cometa.Crypto.Bip32` supplies the two public-key workflows described in section
19.6 without exposing intermediate secrets. Tests reuse the existing pinned
account oracle and root vectors, cover empty/binary passwords, invalid entropy,
public results after GC, and the bounds/smart-constructor agreement law.

Local GHC 9.6.7 verification against native revision
`7a65f2c7309bbba9e86f6aa73214b003fab88aee`: all 161 tests pass, including the
fresh source-distribution consumer. The warnings-as-errors build, eight compiled
examples, external capability and hidden-internal-package checks, native inventory,
Cabal check, Ormolu, HLint and ClangFormat checks pass. Haddock builds with 100%
coverage for the new public module.

The default full Valgrind run completes all 161 tests in 207.28 seconds, but
reports one definitely lost 2-byte allocation in GHC RTS
`stgMallocBytes -> scheduleDoGC -> scheduleWorker`; indirect and possible losses
are zero. Disassembly identifies the capability-sized `idle_cap` allocation in
pinned GHC 9.6.7 `rts/Schedule.c`; the loss stack contains no native crypto frame.
A separate source-identical consumer build, relinked with `-rtsopts` to permit
`+RTS -N2 -I0`, completes all 161 tests in 168.89 seconds with zero errors and
zero definite, indirect or possible losses, without suppressions. Disabling idle
GC supports a runtime shutdown/GC interaction hypothesis; this single controlled
run does not prove the cause or establish a clean default-runtime result. No
runtime-option workaround or suppression was added to CI.

The previous hosted Linux/GHC 9.6.7 job timed out at 240 seconds during callback
reentry (exit 124). Its termination summary reports zero errors and zero definite,
indirect or possible losses, but cannot establish a normal-exit memory result.
CI now allows 600 seconds for the same full Valgrind command and checks; hosted
rerun results remain separate evidence to review.

The merged P04 ergonomics follow-up (PR #9) completed hosted run
`41940246921`: all nine jobs passed. The normal `-N2` Valgrind job completed
all 161 tests in 161.44 seconds with zero errors and zero definite, indirect or
possible losses, without suppressions. This resolves the pending hosted result;
the separate local two-byte RTS finding above remains historical evidence.

### P05 first slice: typed credentials and Shelley addresses

`Cometa.Credential` provides abstract 28-byte `KeyHash Payment`, `KeyHash Stake`,
and `ScriptHash` values with pure length validation. `Credential role`
distinguishes key and script authority. Nominal roles protect payment/stake
key hashes and credentials from coercion; importing bytes explicitly asserts
the intended role. Script hashes can occur in either role. Hash import does not
compute a key or script hash; `fromPublicKey` computes the Ed25519 public-key
hash and returns a credential directly through `IO (Either Error ...)`.

`Cometa.Address.Shelley.Address` supports base and enterprise payment forms;
`Cometa.Address.Reward.RewardAddress` separately represents reward accounts.
Both accept key/script credentials and support total assembly, credential
inspection and exact pure byte conversion. Payment authority is total for
`Address`; only its stake authority is optional. `RewardAddress` has a total
stake credential observer. `Cometa.NetworkId` defines the shared abstract
four-bit network tag, re-exported by Shelley for convenience. Byte parsing
rejects unsupported forms and the other family's headers with
`UnsupportedAddressType`, and requires exact lengths. Bech32 conversion is pure:
`toText` returns `Text`, and `fromText` returns `Either Error ...`. Text parsing
accepts lowercase or all-uppercase, rejects mixed case, and requires matching
form/network prefixes, ASCII input
and at most 120 characters. Text output is canonical lowercase. Network
IDs are 0..15, with mainnet 1 and conventional testnet 0; they are not network
magic values and do not identify preprod or preview.

The native pin advances to the merged revision
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, whose tree is identical to the
previous `7a65f2c7309bbba9e86f6aa73214b003fab88aee` pin. The refreshed inventory
still contains 231 headers and 3,881 symbols. The change records the merged
upstream dependency without changing the native implementation.

Pointer and Byron addresses are deliberately deferred. The pinned native pointer
path has truncation/strictness issues, and Byron needs a separate strict import
contract; the public API therefore makes no generic-address promise. Later P05
work must revisit those forms, assets/values and collections. This slice does not
complete P05. The guide teaches a public-key-to-base-address workflow through the
compiled `cometa-addresses` example, and keeps native ownership details out of
public instructions.

#### Established-library API review

The address workflow was reviewed against primary documentation and source on
2026-11-05. Future public API design must perform this review before choosing
interfaces, as required by `AGENTS.md` and `CODING_CONVENTIONS.md`.

- **cardano-api**, revision `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`:
  [address documentation](https://cardano-api.cardano.intersectmbo.org/cardano-api/Cardano-Api-Address.html)
  and [address source](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Address.hs).
  The caller supplies network, payment credential and stake reference to
  `makeShelleyAddress`; reward accounts use the distinct `StakeAddress` type and
  `makeStakeAddress`. Payment and stake credentials distinguish key and script
  authority. Cometa adopts the payment/reward type boundary so a reward account
  cannot later be supplied where a transaction destination is required. Cometa
  does not reproduce cardano-api's era-indexed hierarchy or its broader native
  ledger dependency graph.
- **Atlas**, revision `c3adfb416242ea25a244bfaa1614213eecdc55d9`:
  [address source and documented examples](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Address.hs).
  `addressFromCredential` takes network, payment credential and optional stake
  credential. The distinct `GYStakeAddress` has its own credential construction,
  parsing and encoding, with documented round-trip usage. Cometa follows this
  separation. Its named `base` and `enterprise` constructors deliberately make
  the two supported payment forms explicit rather than requiring a `Maybe` stake
  argument. Expected failures remain structured errors; Cometa does not adopt
  Atlas's partial convenience parsers.
- **cardano-addresses**, revision `046ff9ccad4526c106e937c8e06a10af617f613a`:
  [Shelley source and worked examples](https://github.com/IntersectMBO/cardano-addresses/blob/046ff9ccad4526c106e937c8e06a10af617f613a/lib/Cardano/Address/Style/Shelley.hs).
  The examples derive keys, choose payment/delegation credentials, then construct
  payment, delegation or stake addresses. Credential constructors accept public
  keys, extended public keys, hashes and scripts. This supports Cometa's direct
  `fromPublicKey` workflow, avoiding manual hash import in the common case.
  That library shares an `Address` representation across these forms; the separate
  reward-account type is therefore a deliberate Cometa safety decision, not a
  universal Haskell convention.

The reviewed workflow is public-key derivation, role-specific credential creation,
address assembly, then text interchange with one error boundary. All three
libraries provide pure address rendering; Cometa likewise keeps Haskell-owned
address construction, inspection, byte conversion and text conversion pure.
The established `bech32 >=1.1.10 && <1.2` package supplies the codec;
`encodeLenient` supports Cardano addresses beyond Bech32's general 90-character
limit. Strict address-family, payload-length and prefix validation remains in
Cometa. Malformed text and checksum failures return
`InvalidShelleyAddressText`; rendering validated values is total.

Native address construction and encoding serve only as test oracles. Production
address codecs have no FFI boundary and use no `unsafePerformIO`. The native
encoder depends on mutable allocator callbacks, so hiding its effects would
violate the library's purity contract. `Credential.fromPublicKey` remains an
explicit native hash operation in `IO (Either Error ...)`. The compiled guide
example exercises that workflow without application-managed native lifetimes.

#### Verification

The final GHC 9.6.7 build resolves `bech32-1.1.11`. All 173 tests pass locally
and in a fresh source-distribution consumer, including 16 pinned vectors,
128 native form/network comparisons and shrinking round-trip properties.
The packaged example runs successfully. External-consumer checks compile two
valid workflows and reject four invalid role/address-family uses.
Warnings-as-errors build, Ormolu, HLint, ClangFormat 18, Cabal package checks,
native inventory and strict Sphinx HTML checks pass. The four new public modules
have 100% Haddock declaration coverage.

The full normal-runtime Valgrind run (`--num-threads=1 +RTS -N2`) completes all
173 tests in 208.08 seconds with zero errors and zero definite, indirect or
possible losses, without suppressions. This uses a fresh static native build
from the merged pin with the repository's CI recipe (`CARDANO_DISABLE_IPO=ON`),
rather than the earlier local LTO archive. PR #10 subsequently completed hosted
run `41954406634` with all checks successful.

### P05 next slice: asset identities and signed values

The approved slice adds pure, Haskell-owned `Cometa.AssetName`, `Cometa.PolicyId`,
`Cometa.AssetId` and `Cometa.Value`. Asset names contain arbitrary 0..32 bytes;
UTF-8 text import checks encoded byte length and text inspection is optional.
Hex is explicit (`fromHex`/`toHex`). Policy IDs contain exactly 28 bytes and
convert to/from validated `ScriptHash` values without revalidation.
`AssetId` distinguishes `Ada` from `Native PolicyId AssetName`, including an empty
native name. These constructors cannot bypass either component's invariants.

`Value` is a normalized map of asset IDs to signed, arbitrary-precision `Integer`
quantities: duplicates add, cancellation removes zero, missing quantities are zero,
and lists use Ada-first then policy/name byte order. `Semigroup`/`Monoid` add values;
`difference available required`, `negate` and `scale` retain negative results.
There is no `Num` or `Ord Value`. `isNonNegative` is inspection, not proof of ledger
output validity. The compiled `cometa-assets-values` example teaches import,
assembly and balance inspection with one error boundary.

#### Established-library API review (before design, 2026-11-05)

- **cardano-api**, `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`:
  [Value implementation](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Value/Internal.hs)
  uses `Integer`, Ada/native alternatives, duplicate summation and missing-as-zero
  selection. [Parser workflow](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Value/Internal/Parser.hs)
  first evaluates signed additions/negations, then checks output nonnegativity or
  mint's zero-Ada rule. Cometa adopts that separation. Qualified `Value.fromList`
  keeps ordinary list assembly explicit; upstream now prefers `IsList.fromList`.
- **Atlas**, `c3adfb416242ea25a244bfaa1614213eecdc55d9`:
  [Value source and doctests](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Value.hs)
  normalize all zeros and use signed subtraction and a separate nonnegative check.
  [Gift caller](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Test/Privnet/Examples/Gift.hs)
  builds/signs/submits token payments, then compares queried balances with -10/+10
  token deltas; [mint caller](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Test/Privnet/Examples/Misc.hs)
  composes input and mint requirements, submits, and selects the minted balance
  delta. These motivate signed reusable values. Cometa omits partial `IsString`
  token parsing and lexicographic `Ord Value`; UTF-8 and hex imports are explicit.
- **plutus-ledger-api**, `4f878f6226a0cb554ce2e9b901ecf96555760770`:
  [Value source](https://github.com/IntersectMBO/plutus/blob/4f878f6226a0cb554ce2e9b901ecf96555760770/plutus-ledger-api/src/PlutusLedgerApi/V1/Value.hs)
  documents unchecked currency/name wrappers, signed pointwise algebra and no
  total quantity order. `flattenValue` drops zero but is unsorted and assumes no
  duplicates. Cometa validates identities and normalizes an off-chain map; this
  does not justify normalizing future raw Plutus Data maps or losing their order.

The native pin remains `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`.
Its `transaction_body/value.c` stores coin in `int64_t`, casts unsigned CBOR coin
without a bound check, and performs unchecked signed arithmetic; asset maps also
store `int64_t`. Native map operations have different duplicate/zero semantics.
Production values therefore use no C casts or arithmetic; native tests compare
only a safe signed-64-bit subset. Future boundaries must check their actual
per-use bounds before marshaling. This slice adds no value CBOR, fingerprint,
output wrapper, mint builder or general native collection API. Pointer/Byron
addresses and remaining collections still belong to later P05 work.

#### Verification

All 183 tests pass with warnings treated as errors, including a fresh source
package consumer. The packaged assets/value example prints the expected remaining
8,000,000 lovelace and 17 token units. Ormolu, HLint, ClangFormat 18, Cabal checks,
native inventory and strict Sphinx HTML pass; all four new public modules have
100% Haddock declaration coverage. The clean-package check caught unsupported
HLint pragmas in the law tests; these were replaced with narrowly scoped
`Value.propLaws` exceptions in `.hlint.yaml`, leaving compiler warnings enabled.

The normal-runtime full Valgrind run completes all 183 tests in 194.44 seconds,
but exits with one 2-byte definite loss allocated by GHC 9.6.7's
`stgMallocBytes -> scheduleDoGC -> scheduleWorker`, matching the earlier P04
runtime finding. Indirect and possible losses are zero. A targeted run of all
10 new asset/value tests, including their native oracle and 400 generated
property cases, passes in 2.52 seconds with zero errors and zero definite,
indirect or possible losses. Both runs use `+RTS -N2`, with no suppressions or
runtime-option workaround. The focused result does not replace or establish a
clean full-suite result; hosted full-suite validation remains a separate gate.

#### GHC 9.6.7 Valgrind CI workaround

The hosted Linux/GHC 9.6.7 Valgrind job passed all 183 tests in 265.48 seconds,
then failed its leak gate on the same 2-byte definite loss from
`stgMallocBytes -> scheduleDoGC -> scheduleWorker`; indirect and possible losses
were zero. In the pinned [GHC 9.6.7 scheduler source](https://github.com/ghc/ghc/blob/ghc-9.6.7-release/rts/Schedule.c#L1555-L1605),
`scheduleDoGC` allocates one `bool` per capability before yielding to
`requestSync`; its subsequent shutdown return can bypass release. The stack,
two-capability allocation size and earlier controlled run support this shutdown
race diagnosis; they do not establish a new Cometa native allocation failure.

The test executable now permits RTS options with `-rtsopts`. Only the pinned
Valgrind CI invocation adds `+RTS -N2 -I0`: the [GHC 9.6.7 RTS guide](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/runtime_control.html#rts-flag--I)
defines `-I0` as disabling idle GC. Allocation-triggered collections and explicit
`performGC` tests remain active, and ordinary tests retain their default idle-GC
behavior. No suppression or library runtime default is added. This is a scoped
CI workaround for the runtime shutdown race, to revisit when upgrading the
Valgrind job's GHC version.

The rebuilt executable passes all 183 ordinary tests with default idle-GC
behavior. The complete local Valgrind run with `-N2 -I0` passes all 183 tests in
188.32 seconds with zero errors and zero definite, indirect or possible losses,
without suppressions. Hosted run `41963426422` subsequently completed successfully across all eight
workflow jobs, including Linux/GHC 9.6.7 Valgrind and Intel macOS.


### P06: data, metadata and scripts

This batch groups related domain APIs into one PR, following the maintainer's
request for larger coherent reviews. Public data values and codecs remain pure;
native hashing and script parameter application remain explicit effects. The
established `cborg` package supplies CBOR parsing and encoding, while `aeson`
supplies detailed metadata JSON. Neither requires cardano-api or the Plutus
Haskell dependency graph. Original bytes and semantic values are kept distinct
where encoding changes could alter identity.

The API decisions below were reviewed before bulk implementation. This batch
also brings forward transaction metadata from P08 and guard scripts from P12;
the ledger retains original planned phases so those dependencies stay visible.

### P06 Plutus Data API review (before implementation, 2026-11-05)

Primary source reviewed:

- cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, [ScriptData source](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Plutus/Internal/ScriptData.hs): the five semantic alternatives use arbitrary `Integer`, bytes, lists and association-list maps. `HashableScriptData` keeps original bytes alongside semantics; its CBOR decoder consumes the complete input and hashing uses preserved original bytes. Its explicit warning forbids treating reserialization as preservation of hash identity.
- plutus-core / plutus-ledger-api `4f878f6226a0cb554ce2e9b901ecf96555760770`, [PlutusCore.Data implementation](https://github.com/IntersectMBO/plutus/blob/4f878f6226a0cb554ce2e9b901ecf96555760770/plutus-core/plutus-core/src/PlutusCore/Data.hs): five alternatives, ordered duplicate-preserving map pairs, arbitrary integers, definite and indefinite collections, constructor tags 121..127 / 1280..1400 / 102. Byte leaves and big integer payloads are chunked into at most 64 bytes. Decoding a definite byte leaf longer than 64 bytes is rejected. Extended constructor alternatives decode as unsigned `Word64`; the upstream semantic `Integer` constructor can produce encodings that cannot decode if outside that range.
- Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, [Datum source and doctests](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Datum.hs), [Gift caller](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Test/Privnet/Examples/Gift.hs): build a semantic datum using `datumFromPlutusData`, attach to outputs, optionally select inline datum. The source warns that round-tripping its semantic datum through the API loses original CBOR. Its documented constructor/number/list/bytes example supplies a useful complete nested assembly case.

Caller workflow: assemble semantic Haskell values without native scopes; serialize new datum once; decode external datum into a protected exact-byte wrapper; inspect semantics without changing that wrapper; hash preserved bytes through an explicit native `IO` boundary. Constructing a fresh value from inspected semantics deliberately creates fresh encoding identity. Invalid CBOR has one `Either Error` boundary and no native allocation.

Adopted differences: constrain constructor alternatives to `Word64`, matching the actual ledger decoder, to guarantee all assembled values round trip. Keep arbitrary signed `Integer` for integer leaves. Expose semantic constructors since every combination is valid; hide encoded-wrapper constructors because independently replaceable bytes/semantics would violate identity. Map equality and ordering retain entry order and duplicate keys. Encoded equality compares exact bytes; semantic equality is available explicitly through inspection. No `Read`, `Num`, `IsString`, unrestricted native handles or hidden native purity.

Native audit: pinned cardano-c `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, `lib/src/plutus_data/plutus_data.c`, `plutus_list.c`, `plutus_map.c`, `constr_plutus_data.c`. The native data layer caches original bytes. `cardano_plutus_map_insert` appends retained key/value pairs even when keys duplicate; keyed lookup alone cannot snapshot duplicate-preserving maps. `cardano_plutus_data_clear_cbor_cache` recursively clears caches. There is no dedicated datum hash entry point, so the existing explicit native BLAKE2b boundary over exact original bytes supplies the 32-byte datum digest.

Approved implementation choices: `Cometa.PlutusData` exposes the semantic ADT and opaque `EncodedPlutusData`; `decodeCbor`, `toCbor`, `toData`, `fromData`, `encodeCbor`, and explicit `hash`. The public codec uses established `cborg >=0.2.10 && <0.3`; domain-specific traversal checks 64-byte chunk limits and constructor forms without a generic hand-written CBOR parser. Encoded equality/ordering compare exact bytes. Semantic equality/ordering compare tree structure including map order and duplicates. There is no extra datum-hash type in this batch.

Native conformance oracle traverses every node through typed getters, snapshots duplicate maps through separate indexed key/value lists, records kind counts / alternative sums / bigint bit lengths / byte sizes, then recursively invalidates native caches and reserializes. The Haskell test compares that independently emitted semantic tree and statistics to public values. Getter results are released deterministically, including failed partial outputs; integer extraction returns a clone. No native owner escapes the synchronous test-only boundary, and no global allocator is replaced. Production datum hashing uses the existing audited explicit native Blake2b boundary with operation-scoped ownership.

Validation includes typed native traversal, pinned integer encodings and hashes,
encoding-identity checks, arbitrary-precision properties and cancellation cleanup.


# P06 metadata review (2026-11-05)

Before API design reviewed actual source at:

* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, `cardano-api/src/Cardano/Api/Tx/Internal/TxMetadata.hs`: https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/TxMetadata.hs
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, `src/GeniusYield/Types/TxMetadata.hs` and `TxMetadata/Internal.hs`: https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/TxMetadata.hs

cardano-api stores transaction labels in `Map Word64`, nested maps in ordered pair lists, lists as lists, and numbers as Integer. Its Semigroup gives left precedence. It validates lengths after raw construction; Atlas hides its value constructors and validates number/bytes/text once with Maybe, then supports total lists/maps and splitting long UTF8 messages into chunks. Atlas's `metadataMsgs` caller uses label 674 and a map containing a `msg` list. Cometa adopts validated hidden values and total composition, with structured errors rather than Maybe. Both upstream validated number APIs use symmetric `-(2^64-1)..2^64-1`, while their source comments differ. Cometa must explicitly state its chosen primitive CBOR boundary rather than copying inconsistent comments. cardano-api detailed JSON uses one-field objects `int`, `bytes`, `string`, `list`, `map`; maps are arrays of objects with k and v fields. This preserves nested map duplicates and order. Arbitrary natural JSON cannot preserve all metadata constructors.

Native audited pin: `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, sources in `lib/src/auxiliary_data`.

`metadatum.c` constructors retain list/map/byte-buffer inputs, clone bigint inputs, and own allocated strings. Conversions return retained maps/lists/buffers, cloned bigints, or copied strings. `from_cbor` owns recursive children and frees them on each failure. It accepts tagged bignums and oversize byte/text strings that its encoder later refuses. Cometa's schema must validate before admitting Haskell values. Text decoding does not itself enforce valid UTF8. Native arbitrary JSON cannot encode bytes or nontext map keys; the detailed schema is independently preferable for lossless interchange.

`metadatum_map.c` insertion and decoding append ordered pairs and preserve duplicates; get chooses first equal key. Indexed get retains key and value. `metadatum_list.c` insertion retains each child; indexed get returns a new reference. `transaction_metadata.c` insertion and CBOR decoding append entries then sort by numeric label. Duplicate labels remain; comparator returns 1 even for equal labels, and lookup chooses the first match. This is unsuitable for exact representation preservation and its duplicate winner is not an application contract. Cometa rejects duplicate transaction labels, uses a validated semantic Map, and keeps original CBOR in a separate abstract wrapper.

No native metadata-specific hash exists. `auxiliary_data.c` computes BLAKE2b-256 of the original cached auxiliary-data CBOR, which includes script/era-dependent outer structure. A digest of an encoded transaction metadata map must never be presented as the full auxiliary-data hash. Imported metadata must retain its exact bytes; normalized re-encoding is explicit and may change hashes.

Production metadata values use pure cborg codecs. Native domain objects appear
only in tests, with scoped cleanup; constructing metadata requires no FFI call.

## Implemented decisions

Approved pure boundary uses cborg >=0.2.10 && <0.3 and Aeson >=2.2 && <2.3 with Scientific >=0.3.7 && <0.4. `Metadatum` is abstract with total inspection `View` and checked leaves; primitive integer range is deliberately -2^64..2^64-1 (one extra negative endpoint compared with upstream validation). `Metadata` hides a unique-label Map and rejects duplicate imports with `DuplicateMetadataLabel`; left-biased Semigroup/Monoid matches cardano-api. There is no arbitrary schema nesting cap, because total list/map construction must retain semantic encode/decode round trips. Leaf lengths remain bounded.

`EncodedMetadata`/`EncodedMetadatum` retain exact ByteString bytes separately from semantic values; equality compares exact representation. Pure encoding is explicit normalization: minimal integers, definite collections/strings, ascending transaction labels, while nested map order/duplicates survive. This does not claim canonical arbitrary-map sorting. No metadata hash helper is exposed: callers deliberately hash exact bytes using Blake2b, without confusing the digest with auxiliary data identity.

Detailed JSON uses exact Scientific coefficient/exponent conversion rather than floatingOrInteger/toBoundedInteger. Scientific 0.3.10.0 can throw on exponent minBound (negating Int overflows). Tests include direct Scientific and Aeson byte-parsed minBound/maxBound exponents plus zero. The conversion repeatedly divides a coefficient only while decimal trailing zeros allow exact integral conversion, uses Integer for negative exponent magnitude, and constructs powers only for nonnegative exponents <=19. The ordinary metadata smart constructor enforces final primitive bounds.

Native oracle reconstructs every decoded scalar via typed getter and fresh constructor, every map/list recursively through indexed getter/insert/add, and every transaction label/value through fresh transaction metadata. Thus agreement is not cached opaque CBOR forwarding. During strengthening, a test-only duplicate unref defect was found: native unref leaves a pointer nonnull when another reference exists. All released loop obligations are now explicitly nulled before reuse/cleanup. Empty bytes use a nonnull dummy buffer because native new_bytes rejects null even at size zero. These are test-only boundaries; production metadata has no FFI ownership.

The API ledger records all 93 metadatum, list, map, label and transaction
metadata symbols. Native natural JSON and CIP-116 conversions remain pending;
the detailed schema does not substitute for those contracts.


## P06 scripts: primary-source review and native audit (2026-11-05)

Review before API design:

* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, [script source](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Plutus/Internal/Script.hs): `SimpleScript` is an ordinary ADT of signature, slot, all/any/threshold and Dijkstra guard alternatives. Signature uses payment-key hash; guard uses a separate guard credential. `PlutusScriptSerialised` owns compiled bytes, selected by V1/V2/V3/V4 witnesses. `hashScript` dispatches by language. Native composition precedes hashing/address creation. The deserializer removes double wrapping; Cometa deliberately preserves exact imported encodings and never guesses/strips a CBOR layer.
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, [script source](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Script.hs), lines 456 onwards: `GYScript` owns version, bytes and cached API hash; `scriptFromSerialisedScript` imports compiled bytes; `scriptHash` obtains the identifier for addresses/policies; `applyParam` decodes UPLC, applies typed data as a constant and serializes again. It uses unchecked UPLC decoding; Cometa returns native VM errors in IO and takes the explicit Haskell PlutusData ADT, keeping failure at one Either boundary. Runtime versions avoid existential/typeclass ceremony in a library without era-indexed ledger transactions.
* Atlas pinned [simple-script tests](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/tests/GeniusYield/Test/SimpleScript.hs): caller builds nested all/any/threshold/signature/time conditions and compares the retrieved script. No network tests are imported into Cometa; deterministic equivalent assembly is sufficient.

Native audit against cardano-c `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:

* `lib/src/scripts/native_scripts/native_script.c`, all seven alternatives, hash prefix 0 plus exact script CBOR. Leaf script caches retain input CBOR; n-of-k required is size_t and native constructor does not check satisfiability. Thresholds above the number of children are valid, deliberately unsatisfiable conditions. Cometa retains the complete unsigned-64-bit range without a satisfiability restriction; native size_t conversion is confined to the test oracle on the verified 64-bit platform.
* `script_require_guard.c` serializes tag 6 and a typed credential `[0/1, bytes28]`, allowing key and script authorities.
* `lib/src/scripts/plutus_scripts/plutus_v{1,2,3,4}_script.c` stores nonempty compiled bytes, adds one bytestring layer for script CBOR, and hashes prefix 1/2/3/4 plus stored compiled bytes. It does not validate executable UPLC. A compiled payload generally already contains the single CBOR wrapper around Flat; outer script CBOR therefore has two wrappers. These are distinct contracts.
* `lib/src/uplc/tx/uplc_apply_params.c`: VM accepts single-CBOR-wrapped Flat, decodes into arena, applies parameters in supplied order (first becomes innermost application), re-encodes to canonical single-CBOR-wrapped Flat, then frees arena before returning. Result buffer is separately owned. Empty params still decode/re-encode and may normalize. Caller owns result on success; private bridge initializes outputs and cleans partial results.
* `lib/src/scripts/script.c`: combined representation is `[languageTag, payload]`, where native=0, V1..V4=1..4. Decoder fails to consume final array terminator; public pure decoder must enforce exact arity and complete input separately.

All public values should remain Haskell-owned. Only hashing and VM parameter application need native effects. C adapters are limited to parsing marshaled parameters and copying outputs, with deterministic owner cleanup. Imported native conformance vectors retain their Apache-2.0 provenance.

### Implemented public workflow and decisions

`Cometa.Script.Native` has an abstract immutable script plus an inspectable
`NativeScriptView` ADT covering all seven native alternatives. `signature` uses
`KeyHash Payment` like cardano-api; `requireGuard` uses the added nominal
`Credential Guard` role and permits either key or script credentials. `allOf`,
`anyOf`, `atLeast`, and slot restrictions assemble values totally. Thresholds and
slots are Word64; a count above child length retains the valid unsatisfiable
condition. Import validates exact schema, field counts, hash lengths and full
consumption. cborg decodes owned semantic values while byte spans preserve every
original child encoding. New parents retain the exact imported bytes of children.
`Eq`/`Ord` compare exact script encoding; no mutable native handle is public.

`Cometa.Script.Plutus` owns a V1/V2/V3/V4 version, nonempty compiled bytes and exact
outer script encoding. `fromBytes` is intentionally opaque and checks only
nonemptiness; `decodeCbor` additionally checks one outer bytestring. Neither
claims UPLC executability. The compiled payload and outer representation are
separate: `450100002499` compiled code has script CBOR `46450100002499`.
Equality/ordering compare version then exact outer representation. Hashing uses
version prefix plus compiled bytes, so two outer encodings may differ in equality
while sharing the same script hash. `Cometa.Script` supplies public `Native` and
`Plutus` sum alternatives; its combined envelope is normalized on encoding, while
the hash-bearing payload retains identity.

`applyParams` takes `[Cometa.PlutusData.PlutusData]`, marshals its typed `List`
encoding, and invokes native UPLC in explicit IO. VM decoding/reencoding may
normalize code even for empty parameters; input scripts remain unchanged and the
result retains the declared version. Data constants apply left to right. The
private C bridge is limited to parameter decoding and owner cleanup; Haskell owns
all inspection, construction, CBOR, language dispatch and exact hash preimages.
`withOwnedOutput` installs cleanup before acquisition, scopes partial outputs and
copies buffer bytes before release; all borrowed Haskell storage outlives the
safe noninterruptible call. No finalizer, unsafePerformIO or application-managed
native lifetime is introduced.

Independent digest constants were computed with Python hashlib BLAKE2b-224 over
explicit prefix/preimage bytes. Native conformance tests construct typed scripts,
parse into C, inspect their alternative and recursively clear caches before
native reserialization/hash, so cached forwarding alone cannot establish a pass.
Generated script trees also run this native comparison. Pinned apply-parameter
vectors cover no params, zero, above-uint64 integer and ordered mixed params;
tests also compare sequential application to simultaneous application, all four
versions, malformed input, encoding identity and original/result snapshots after
repeated success/failure/GC. Started barriers with forkFinally, cancellation and
bounded unwind checks exercise safe native cancellation, followed by independent
successful reuse. These checks exercise deterministic local programs only.

`examples/Scripts.hs` is the compiled task-oriented native-policy/typed-Plutus
workflow documented in `docs/userguide/scripts.md`, with one ExceptT boundary.
Script JSON/CIP-116 conversion remains explicitly pending; no unsupported JSON
schema is advertised. Mutable setters/clones map to immutable reconstruction and
sharing, rather than effectful wrappers. The per-symbol mapping and remaining work are recorded in `native-api.csv`.


#### Integrated verification

The warnings-as-errors GHC 9.6.7 build and all 214 tests pass, including a fresh
source-distribution consumer. Consumer CI now explicitly enables test suites in
both build and test commands: an extracted source package has no repository
`cabal.project`, and Cabal otherwise selected a plan with tests disabled.
The three new examples compile as ordinary executables. All five new public
modules have 100% Haddock declaration coverage. Strict Sphinx HTML, Ormolu,
HLint, ClangFormat 18, Cabal package checks and the native inventory pass.

The complete 214-test Valgrind run finishes in 261.67 seconds with zero errors
and zero definite, indirect or possible losses, without suppressions. It retains
the existing pinned-GHC idle-GC workaround (`-N2 -I0`); ordinary tests retain
normal idle-GC behavior. The final property-generator and semantic-assertion
refinements also pass a focused 31-test domain Valgrind run with zero errors
and zero definite, indirect or possible losses.

The ledger now records 614 implemented/adapted entries across the binding,
compared with 341 before this batch. This is symbol coverage, not an estimate of
remaining engineering effort. Native lifetime plumbing retains internal
visibility without being counted as implemented. Plutus/script JSON and native
metadata natural/CIP-116 JSON remain pending; auxiliary-data transaction
integration and full VM evaluation are separate work. Hosted compiler/platform
validation is tracked on the PR and is not implied by the local Linux results.


### P07: protocol snapshots, updates and governance voting

PR #12 merged as `26d0b6a`; hosted run `41967142371` passed all checks before
this batch began. This larger batch adds shared protocol values, snapshots and
sparse updates, governance identities and voting collections. Certificates,
pool registration and governance proposal actions remain separate P07 work.

The following reviews informed the APIs before implementation. Public values
stay pure, and optional fields preserve observed availability rather than
inventing values for unsupported eras. Exact encoding wrappers protect imported
updates and voting procedures whose bytes may contribute to transaction identity.

#### Foundational protocol values review

Native pin: eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1.

Reviewed actual source at cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5:
- https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/ProtocolParameters.hs
- https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/test/cardano-api-test/Test/Cardano/Api/ProtocolParameters.hs
ExecutionUnitPrices stores exact Rational, conversion to ledger bounds through boundRationalEither; CostModel stores [Int64], conversion validates language-dependent evaluator support. Tests explicitly distinguish arbitrary-cost-model ledger conversion from CBOR round-trip.

Reviewed Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9 actual source:
- https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/ProtocolParameters.hs
- https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Common.hs
- https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/IO/Builder.hs
Atlas aliases ledger PParams; maximumFee reads validated execution prices and ExUnits, computes exact Rational products then ceiling. Cometa workflow validates external numerator/denominator once, assembles immutable prices, multiplies via explicit Rational observation, and serializes pure values. No Double conversions.

Native audit:
- common/unit_interval.c new stores uint64 pair without validation, from_cbor tag30+[uint,uint], permits zero denominator and >1. Used for prices, pool pledge influence and reference script multiplier too. Public nonnegative rational rejects zero denominator, subset UnitInterval also enforces <=1. Pair retained unreduced; equality/ordering compare exact numeric values using Integer cross-products. Original pairs remain observable and serializable. No normalization of imported pairs, shortest integer representation on output (not byte-preserving nonminimal CBOR).
- common/ex_units.c uses unsigned uint64 memory then steps array.
- common/protocol_version.c from_cbor/set_minor enforce UINT32_MAX; new omits bound check. Public validation major u64, minor u32 for round-trip closure.
- protocol_params/cost_model.c known-language constructor plus unknown language decode (0..255), signed int64 vector max 2048. Encoding is a two-item stream (language id + costs array), embedded as a map pair by costmdls.c. No Haskell semantic evaluator-validity claim for opaque vectors. costmdls insertion replaces existing key and output sorts raw language ids ascending.
- protocol_params/ex_unit_prices.c array memory price then step price, each native unit_interval pair.
- threshold constructors retain each child; immutable Haskell records avoid lifecycle effects. Threshold ordering follows native constructor/from_cbor order (5 pool / 10 DRep).

No upstream code or tests copied. License: upstream cardano-api Apache-2.0; Atlas Apache-2.0; native Apache-2.0 source remains referenced not copied. Generated properties and independent boundary tests are original.

Public individual cost-model codec intentionally encodes only the cost array, with explicit raw language supplied on decode; the collection codec emits the native language-keyed map. Duplicate external language map keys are rejected, while explicit fromList/insert use last-wins replacement. This avoids silently selecting an ambiguous external model.

Verification delegated to root: cabal build/tests/haddock, C oracle integration and Valgrind. Locally completed Ormolu and HLint with no hints across owned files. No commits made.

#### Protocol parameter review (2026-11-05)

Reviewed before API design, cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5:
https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/ProtocolParameters.hs
https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Compatible/ProtocolParametersUpdate.hs

The compatible API uses typed records grouped by introduction/deprecation era, StrictMaybe fields for sparse changes, nested StrictMaybe for nullable maximum pledge leverage and Peras bootstrap round. createEraBasedProtocolParamUpdate combines groups, createPParams applies changes to emptyPParams. Common fields cover fees, deposits and sizes; Conway adds voting and governance; Dijkstra adds reference-script tiers, pledge/margin, Leios, Peras and reference-input charges. Extra entropy/decentralization are deprecated after Alonzo, version updates after Babbage; minimum UTxO value key15 is absent from native interface.

Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9:
https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/ProtocolParameters.hs
https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Common.hs

Atlas aliases ledger PParams. Real caller buildTxCore takes protocol parameters into GYBuildTxEnv; maximumFee uses minFeeA/B, maxTxSize, exact prices and maxTxExUnits plus tier reference-script fee; collateral uses exact rational percentage. The workflow is obtain a complete snapshot, inspect typed values, assemble a sparse update and apply it immutably. Cometa adopts Haskell-owned typed records and Maybe absence, standard Either errors, explicit exact encoding wrapper. It does not fabricate full parameters by filling missing values with defaults. No era witness exists in the binding; native representability does not assert validity for a particular ledger era.

Pinned cardano-c eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1 audited headers and implementations protocol_parameters.{h,c}, protocol_param_update.{h,c}. Full parameters expose typed setters/getters and no serialization in the audited header. Sparse update CBOR maps keys0..56 excluding15. Dijkstra fields have Word32/Word16 bounds, stride positive Word32. Fields38,53 explicitly distinguish absent and present-null; nested Maybe preserves all three states. Full getters retain reference-valued fields; update pointer-to-pointer getters retain references or report absence. Each obligation must be released once and local pointer nulled even when native unref leaves it nonnull.

Generic native unit_interval permits nonnegative ratios above1; true proportions use validated UnitInterval while pledge influence, costs, multiplier, leverage and healing use NonNegativeRational. Native does not enforce era-specific positive multiplier/healing ledger checks. Entropy decoder ignores variant tag and hash length; Cometa validates [0] neutral or [1,bytes32] deliberately. Native update caches original CBOR; public EncodedUpdate preserves identity and fresh encodeCbor explicitly normalizes. Native full defaults include0/1/empty placeholders and are not a meaningful complete snapshot.

Approved API: Cometa.Protocol.Parameters complete concrete immutable record (no default), Nonce and ReferenceScriptCostStride validated values; Cometa.Protocol.Parameters.Update sparse record, empty, apply, fromParameters; pure codec with opaque EncodedUpdate exact bytes plus semantic inspection, strict duplicate/unknown/trailing rejection. Old proposed-update envelopes deferred.


Availability refinement after review: Parameters retains required common fields,
while deprecated entropy/decentralization and fields introduced after Shelley are
Maybe. Dijkstra nullable fields therefore use Maybe (Maybe value): unavailable,
present-null, and present-value. fromParameters omits unavailable fields; apply
preserves them unless a field is explicitly changed. This permits real Conway
snapshots without invented future defaults. Native lacks key15/minUTxOValue and
old ada-per-word schema, so the snapshot is not a full historical-era validator.

Native oracle: all56 update getters are independently traversed through full
parameter setters/getters and into a newly allocated update. Every acquired
reference is released once and nulled immediately. It exercises full Dijkstra,
Conway-like absent future fields, all56 singleton changes, all nullable states,
neutral nonce, width bounds and random fee changes. No opaque parent cache can
establish agreement. Shared foundation oracles separately inspect rational pairs,
execution values, model contents and threshold fields. Production has no native
owners or IO boundary in this scope.

Native limitations discovered by integrated checks: sparse decoder casts the
indefinite map sentinel to size_t and does not support indefinite maps. Pure
Haskell import deliberately supports them and preserves identity; oracle agrees
on normalized definite maps and additionally tests nonminimal definite integers.
The full max_value_size getter/storage and sparse API are uint64_t but its full
setter takes int64_t with unchecked assignment. Public Haskell preserves Word64
snapshot/update domain. The oracle performs checked conversion and full traversal
only through INT64_MAX; larger values use sparse typed getter/setter alone. It
never calls an incompatible function pointer or narrows out of range.

Independent field mapping test pairs all56 explicitly named singleton updates
with native keys0..14 and16..56 and inspects the serialized map key. This prevents
matching encoder/decoder key-swap bugs from passing a roundtrip. A separate
pinned byte vector selects distinct feeA44,feeB155381,blockrefsize256 and explicit
null leverage. Full scalar fixture values are distinct, plus width maxima and
invalid-overflow matrix cover unsigned bounds.

#### Governance identity and voting API review

Native pin: `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`.

Reviewed actual upstream sources before design:

* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, [VotingProcedure](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Governance/Internal/Action/VotingProcedure.hs). A vote and optional anchor assemble a VotingProcedure; singleton associates voter/action identity; merge rejects overlapping voter/action pairs even when votes agree. Serialized voting procedures use nested ledger maps. Era witnesses supply ledger integration, not a necessary property of standalone immutable vote values.
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, [Governance](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Governance.hs), [Anchor](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Anchor.hs), [DRep](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/DRep.hs). Role-specific committee hot/DRep credentials and stake-pool key hashes distinguish voter authorities. Special DRep delegation targets always-abstain/no-confidence are distinct from credential voters. Anchor URLs are UTF8 byte-bounded (128), hashes are 32 bytes. Action identity has transaction ID and Word16 index. Atlas combineVotingProcedures resolves duplicates right-biased, unlike cardano-api; Cometa makes conflicts explicit rather than silently discard an instruction.
* Actual caller flow: Atlas [TxBuilder.Class](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs) `mustHaveVotingProcedures` (lines 873-874) installs a caller-built `Map Voter (witness,Map ActionId VotingProcedure)` into the skeleton. This establishes identity -> optional anchor -> vote -> voter/action association -> builder integration. Cometa scope ends at standalone voting data/CBOR; witness signing and transaction builder integration belong to later phases. Atlas [DRep privnet caller](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/tests-privnet/GeniusYield/Test/Privnet/DRep.hs) separately validates URL, hashes metadata, assembles optional anchor and uses role-aware DRep identity in registration/update. This supports reusable anchor/credential values for future certificate work without implementing certificates here.

##### Native semantics audit

`common/anchor.c` stores URL in a 129-byte NUL-terminated array and serializes with safe_strlen: embedded NUL truncates. Constructors require 1..128 bytes. Cometa rejects embedded NUL and empty URLs rather than allow silent changes. Text is validated UTF8, not HTTP/URI syntax. Hash bytes exactly 32.

`common/governance_action_id.c` accepts a full uint64 CBOR index, greater than Atlas Word16. Preserve native index range in standalone protocol API and document it. Native CIP129 helper `to_cip29_bech32` takes `byte_t index`, payload 32-byte transaction hash plus one-byte index. This is incompatible with claiming arbitrary uint64 identity text round trips. CIP129 text is explicitly deferred pending a separate standards review and carefully checked narrower boundary.

`voting_procedures/voting_procedures.c` sorts outer voters using voter kind (0 committee key,1 committee script,2 DRep key,3 DRep script,4 pool key) then credential bytes. `voting_procedure_map.c` sorts action keys by transaction hash bytes then numeric uint64 index. Inner insertion APPENDS duplicates. Outer insertion merges repeated voter keys. Serialization traverses duplicate action keys but calls first-match get for each: conflicting duplicate values can be changed. `from_cbor` discards empty inner voter maps. Therefore native decode/re-encode cannot establish exact imported voting CBOR identity.

Implemented semantic collection: unique nested maps, explicit duplicate errors, canonical native ordering for newly assembled values, no Monoid instance that masks conflicts. Decode rejects duplicate outer voters, duplicate inner action IDs, and empty inner maps. Exact EncodedVotingProcedures retains all accepted input bytes (including map order and nonminimal encodings) plus semantic snapshot; `toCbor` is exact and `encodeCbor . to...` is explicitly fresh serialization. Rejection policy is narrower than native permissiveness and avoids native corruption; no external encoding is silently normalized.

Pure owned ADTs and CBOR codecs use existing cborg dependency; native oracles reconstruct typed values and compare bytes/inspect meaning. No native object resources enter public values and no new unsafePerformIO boundary is introduced.

##### Implemented API

The shared API review approved a reusable `Cometa.TransactionId.TransactionId`
(32 bytes, byte/hex import and observation). `ActionId` is a total record of this
validated hash and an ordinary `Word64` index; no additional index smart constructor
or partial numeric instances are introduced. Credential adds `DRep`,
`CommitteeHot` and `StakePool` roles now. Committee-cold role remains deferred
until certificates need it.

Public modules: `Cometa.TransactionId`, `Cometa.Governance.Anchor`,
`Cometa.Governance.ActionId`, `Cometa.Governance.DRep`,
`Cometa.Governance.Voting`. Private `Cometa.Internal.Governance` holds pure
schemas and representations so cborg parser workers do not leak publicly.
Haddock on re-exported declarations describes validated fields and collection
laws. `VotingProcedure` and `Anchor` total record constructors assemble
validated component values; `DRepCredential` distinguishes the credential target.

`Anchor.hashData` delegates the existing BLAKE2b-256 native IO boundary, including
its empty-message native failure; it does not repurpose the `EmptyHash` error,
which belongs to importing an empty digest. The existing native restriction is
documented and tested. A pinned independent Atlas Hello-World digest checks the
payload semantics.

##### Test and lifecycle evidence

`test/Governance.hs`: pinned scalar and complete nested voting collection values
are rebuilt using public Haskell constructors; all five voter forms, optional
anchor choices and three votes, full uint64 index boundaries, UTF8 byte URL
bounds and NUL rejection, malformed/trailing encodings, duplicate/empty inner-map
rejection, representation-sensitive exact wrappers, repeated native lifecycle,
and original Hedgehog scalar/collection round trips and disjoint merge laws.

`test/cbits/governance_oracle.c` decodes typed Haskell-generated bytes, obtains
semantic fields, reconstructs fresh native objects and serializes them, including
rebuilding nested collections with native insertion and sorting. No source CBOR
cache is forwarded. Native credential/anchor/list getters acquire retained
references which are released locally. Borrowed raw hash/URL fields are consumed
while their source owner remains alive. Reused loop pointer locals are explicitly
nulled after unref, since another reference can keep the address nonnull.

`test/Fixtures/Governance.hs` contains the imported Apache-2.0 pin with source
constants recorded in `test/Fixtures/Governance.md`. No live tests or keys are
used. `examples/Governance.hs` demonstrates one error boundary from input
validation and metadata hashing through fresh encoding and exact stored-byte
reload; `docs/userguide/governance.md` literalincludes the compiled example.

The native API ledger retains original planned phases for all 163 scoped
governance symbols. Implemented domain operations map to
`adapted` Haskell-owned APIs; CIP116 JSON, identifier/enum string interchange and
anchor hash hex conveniences remain `pending` with explicit omissions. Public
transaction ID hex conversion is implemented separately from anchor hash hex.

##### Integrated verification

The protocol and governance batch passes all 239 tests with warnings treated as
errors. The same tests pass from an extracted source distribution built as a
separate consumer. All 16 executable examples and the credential/key-handler role
checks pass. The 15 new public modules have complete Haddock declaration coverage;
the strict Sphinx HTML build, Ormolu, HLint, C formatting, C11 warning checks,
package checks, and native inventory checks pass.

The complete test suite also passes under Valgrind in 203.61 seconds, with zero
definitely, indirectly, or possibly lost bytes and zero reported errors. This
uses the existing GHC 9.6.7 idle-GC workaround described above, without Valgrind
suppressions. Ordinary tests retain their normal runtime configuration.

The ledger now records 1,040 implemented or adapted native symbols. This is a
symbol count, not a completion percentage: lifecycle plumbing and deferred domain
operations remain explicitly tracked. Certificates, stake-pool registration,
governance proposal actions, and proposed-update envelopes remain for subsequent
work. Hosted matrix validation is checked on the pull request.

### P07 continuation: certificates, pools and proposals

Merged PR #13's run `41978295643` passed Windows, both macOS runners, Linux
ARM, quality and documentation. Two failures require corrections in this batch.
GHC 9.10 exports `foldl'` from Prelude, making the explicit unqualified
`Data.List` import redundant under `-Werror`; the cost-model fold now uses a
qualified import on both supported compilers.

All 239 hosted Valgrind tests passed, but process shutdown leaked two bytes from
`malloc -> stgMallocBytes -> scheduleDoGC -> schedule -> scheduleWorker ->
workerStart`. The [pinned GHC scheduler](https://github.com/ghc/ghc/blob/ghc-9.6.7-release/rts/Schedule.c#L1689-L1742)
allocates one boolean per capability before `requestSync`; a subsequent shutdown
return can bypass its release. The earlier idle-GC workaround reduced occurrence
but does not prevent this allocation-triggered shutdown race.

The GHC 9.6.7 Valgrind job now uses `test/valgrind/ghc-9.6.7.supp`, matching only
definite leaks with that complete scheduler worker allocation stack, including
the pthread entry frames. Native Cometa/cardano-c allocation frames do not match.
Invalid accesses and other leak stacks remain errors. Default idle GC is restored
for this invocation; no library runtime options change. Reports must distinguish
any suppressed runtime allocation from actual zero-leak observations. Revisit the
suppression when changing the job's compiler; GHC 9.10.3 still contains the same
early-return path, so moving the check to it would not address the cause.


#### Pool API evidence and design review (2026-11-05)

Reviewed exact sources before choosing API:
- cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5, https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Certificate/Internal.hs. StakePoolParameters includes typed operator/VRF, Lovelace pledge/cost, Rational margin, StakeAddress, owner list, relay list, metadata. toShelleyPoolParams converts margin with boundRational and errors if invalid; owner conversion uses Set; relays convert optional IP/port, DNS via ledger validation. Metadata URL uses text bounds and hash bytes. makeStakePoolRegistrationCertificate consumes fully assembled record.
- Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9 https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Pool.hs. GYPoolParams uses role-indexed pool/stake key hashes, VRF hash, Natural pledge/cost, UnitInterval margin, Set owners, ordered relays, optional GYAnchor. GYSingleHostAddr carries optional port/IPv4/IPv6. Ledger conversion is total for valid values; metadata from-ledger conversion contains error if hash invalid.
- Actual complete caller: https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/tests-privnet/GeniusYield/Test/Privnet/StakePool.hs generates pool and owner keys, converts public hashes, imports VRF hash, gets protocol minimum cost, validates margin, assembles reward account, owner Set, relays and metadata, builds registration certificate, signs with pool/owner/payment keys and submits. Later record update replaces metadata then registration updates; retirement uses pool hash and epoch. Ordinary Cometa examples cover offline input→assembly→persist/reload→record update→certificate, not network/build/signing work from later milestones.

Contracts adopted: role-specific operator/owner hashes, exact UnitInterval (reused existing module), Set owners/list relays, three relay sum alternatives, Maybe optional metadata/port/IP. Differences justified: Word64 money follows actual native uint64 bounds and existing protocol convention, avoiding unchecked Natural→native truncation; upfront validation avoids upstream partial error branches. Separate pool URL permits native empty and <=128 UTF8 bytes while governance anchor URL requires nonempty. Separate metadata digest and VRF hash prohibit accidental interchange; BLS extension represents native optional 96+48-byte field although pinned reviewed Haskell APIs do not expose it. No claims of cryptographic BLS verification or ledger-era acceptance. Public CBOR parameters is one array; native flat group remains private for certificates and differential oracle. This follows caller values, not native embedding details.

Native audit: eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1, lib/src/pool_params/*.c and corresponding include/test trees. pool params serializes nine flat fields, or ten with BLS after the VRF hash; decoder accepts an explicit null BLS field, encoder omits it. Margin is tag 30 followed by `[uint64, uint64]`, existing safe UnitInterval validates denominator/nonunit cases. Owners sorted hash bytes with tag 258; native add does not deduplicate and decode permits duplicates, so pure decoder rejects duplicate owners. Native getters return retained refs except byte/text/port snapshots; oracle releases every getter owner. Name get_dns_size includes terminator (subtract1), metadata URLsize excludes terminator. IPv4/6 require exactly 4 or 16 bytes; native IPv6 textual parser only expanded notation; public pure text parser deliberately improves caller workflow with standard short groups, single :: compression and final dotted IPv4 suffix. Invalid repeated compression and over/underfull groups are tested. DNS names of 1–64 UTF-8 bytes and metadata URLs of 0–128 UTF-8 bytes reject embedded NUL upfront rather than native truncation. No unsafePerformIO or arbitrary native boundary used; pure codecs cborg.

Tests: public-field reconstruction of exact pinned pool_params.cpp CBOR/nullmetadata/BLS/nullBLS, pool_metadata.cpp and bls_key.cpp goldens, relay.cpp three alternatives. Fixtures retain native revision/path Apache-2.0 provenance in test/Pool.hs. Generated typed pools compare exact public encoding with native fresh getter/new/add reconstruction, after explicit array framing transformation; all port/IP alternatives, maximum uint64 fields, empty owners, relay duplicates, optional metadata/BLS, invalid hashes/IP text/UTF8/NUL/arity/duplicate owners/trailing/truncation. IP textual roundtrip property. 100 repeated native reconstruction scopes. C oracle built against configured stock headers, formatted stock ClangFormat18. Haskell Ormolu0.8.0.2, HLint3.8 pass; integrated verification is recorded below. Corrected native oracle definite-array framing to omit write_end_array (native function emits indefinite break). Standalone linked C oracle checks confirm all three full golden parameter variants agree after correction.

#### Certificate API review and evidence

Reviewed before implementation:

* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Experimental/Tx/Internal/Certificate/Type.hs and https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Compatible/Certificate.hs; pool integration https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Certificate/Internal.hs. Actual ADT wraps era-indexed ledger certificate; stake registration/delegation and DRep operations use requirements carrying explicit era/deposit information. CBOR serialization delegates to ledger; pool records separate operator/VRF/BLS and metadata/relay forms.
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Certificate.hs. `GYCertificatePreBuild` receives caller credentials and delegation targets; `finaliseCert` fills stake/DRep deposits from queried protocol parameters. `certificateToApi` translates each ADT constructor to cardano-api requirements. Cold/hot/DRep/pool roles are distinct. Separate optional anchor is shared across DRep registration/update and committee resignation.

Complete Cometa workflow: validate runtime hashes and metadata once; assemble explicit deposit-bearing certificates and delegation target using total constructors; collect in transaction order; encode for storage; reload through one Either Error boundary; inspect semantic data or return exact original CBOR. examples/Certificates.hs compiles this deterministic register-DRep+delegate workflow. Differences: Cometa currently exposes standalone data, not an era-indexed transaction builder, so does not infer deposits or imply ledger-state/era validation. Native numeric schema is uint64, represented by Word64 with documented lovelace units, never floating point. Legacy certs and MIR remain available for decoding historical data; unsupported signed MIR adjustments are explicitly rejected.

Native audit: `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, lib/include/cardano/certs/*.h and lib/src/certs/*.c. All cert tags 0–18 and both MIR alternatives audited. Fresh certificate encoding is definite, minimal integers; PoolRegistration flattens nine/ten field groups and validates reported arity, including null-BLS omission alias. Native genesis constructor does not enforce protocol hash sizes, so Cometa uses stricter validated 28/28/32-byte role hashes. Native MIR quantities unsigned uint64 (negative ledger deltas omitted). MIR rewards native insert sorts by credential but permits duplicates; native first-match retrieval can conflate duplicate amounts. Cometa uses unique Map and rejects imported duplicates to avoid semantic loss; sorted output agrees with native comparison.

Native certificate_set_add merely pushes an element; no uniqueness or sorting. Public Certificate.Collection preserves order and duplicates, fresh tag 258; decode optionally tagged/indefinite arrays and exact original envelope. EncodedCertificate/EncodedCertificates equality includes exact bytes; semantic ADT equality is constructor/field comparison. Fresh encoding deliberately does not retain signed transaction identity; exact containing transaction must be preserved when required.

Ownership: public data/codecs are pure and Haskell-owned; no unsafePerformIO/no persistent native resources. Test oracle parses public fresh encodings, obtains retained subtype getters, snapshots scalar fields and passes children into new constructors, then reconstructs fresh generic wrapper and serializes. All returned subtype/child references unref independently from parent obligations (even if parent retains pointer); no conditional ownership inferred from pointer nullness. MIR as/get_key_value_at and certificate_set_get retained outputs balanced. Pool envelope oracle reuses retained pool params whose individual fields are independently reconstructed by Pool oracle. No ABI inference outside C adapter. Native JSON, diagnostic and refcount/lifecycle APIs remain explicitly pending; immutable field replacement adapts domain setters rather than exposing mutable handles.

Tests: test/Certificates.hs plus test/cbits/certificates_oracle.c. Public typed construction covers all19 tags/both MIR forms, special and credential DRep targets, key/script roles, optional anchors, uint64 CBOR width boundaries0,23,24,255,256,65535,65536,2^32-1,2^32,max. Hedgehog generates all alternatives from varied hashes/full-range Word64 and compares fresh native reconstruction. Imported corpus is Apache-2.0.0 native lib/tests/certs/*cert.cpp at pinned revision; inline fixtures retain filename/constant name. Exact nonminimal/indefinite, trailing bytes, invalid codes/hash lengths/arity, duplicate MIR rewards, signed adjustments and >uint64 quantities, ordered duplicate collection, optional tag, repeated native reconstruction covered. Lifecycle failure/cancellation coverage is not claimed for pure codecs; C oracle deterministic cleanup exercised repeatedly and by aggregate Valgrind as root verifies.

#### Governance proposals and legacy update API review

Reviewed before implementation:
* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, [ProposalProcedure](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Governance/Internal/Action/ProposalProcedure.hs). `createProposalProcedure` assembles deposit, reward authority/network, action and anchor. Seven action alternatives carry optional predecessors and policies. `ProposeNewCommittee` accepts Rational then uses partial `error` if outside [0,1]. Cometa instead accepts validated UnitInterval, RewardAddress, credentials, hashes and protocol Update, so assembly is total; only input validation fails. Era witnesses remain ledger integration concerns outside standalone values. cardano-api creates proposal identifiers from Word16; Cometa follows the pinned native standalone Word64 schema and documents this distinction.
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, [Governance](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Governance.hs). `GYProposalProcedurePB` takes return address/action/anchor; `completeProposalProcedure` adds externally obtained deposit. Constitution is anchor plus optional script; GovAction is a seven-case ADT; typed cold credentials distinguish committee management from hot voting. Cometa follows these typed immutable components and total assembly, using bounded Word64 native amounts rather than unbounded Natural. Deposit discovery belongs to query integration. Cometa rejects duplicate map keys explicitly; removal credential multiplicity and proposal insertion order are retained, because proposal index is identity-relevant. Exact wrappers preserve original bytes independently from semantic values.

Complete workflow: validate runtime reward-account bytes, anchor URL/hash and any policy hash once; create a typed action from validated components; assemble Proposal with queried deposit; collect ordered proposals preserving duplicates and their indices; encode fresh CBOR or retain imported wrapper bytes unchanged. A single Either boundary handles expected failures. No native objects persist in public values.

Native ownership evidence: cardano-c pin `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, `lib/src/protocol_params/update.c` `cardano_update_get_proposed_parameters` borrows its map (plain assignment without ref). The reconstruction oracle keeps its source alive and never unrefs this borrowed pointer; `cardano_update_new` retains the supplied map. Action field getters, proposal action conversion/common field getters and indexed committee/withdrawal/proposed-update getters retain results; the oracle releases each local getter owner once. Fresh treasury maps are rebuilt through indexed account/amount snapshots and insertion. Repeated native reconstruction and Valgrind cover these mixed ownership contracts.

The independent certificate getter audit checked the actual implementations,
including indirect retention through `cardano_array_get`. Certificate subtype,
MIR credential and optional BLS-object getters retain references; BLS byte getters
borrow arrays until their key owner is released. The legacy update getter is an
exception: `cardano_update_get_proposed_parameters` returns a borrowed map. An
incorrect release in the new test oracle caused heap corruption during initial
integration; removing it and reconstructing the treasury withdrawal entries
resolved the failure. These test adapters hold no public persistent handles.

#### Integrated continuation verification

All 264 tests pass with warnings treated as errors, including the fresh
source-distribution consumer (6.39 seconds). All 19 examples run successfully.
Key-handler capability controls and ten credential-role compile-fail checks
pass. The 11 new public modules have complete Haddock declaration coverage;
strict Sphinx HTML, Ormolu, HLint, stock ClangFormat 18, package checks and the
3,881-entry native inventory also pass.

The complete Valgrind run passes all 264 tests in 207.87 seconds, with zero
errors and zero definitely, indirectly or possibly lost bytes. No allocation
was suppressed in this particular run. Default idle GC is enabled; the narrow
pinned-runtime suppression remains available for the intermittent shutdown
allocation observed in hosted CI.

The ledger now contains 1,613 implemented or adapted symbols. P07's typed
certificate, pool and proposal domains are implemented; explicitly deferred
JSON/text conversions and internal lifecycle entries remain tracked rather than
being counted as complete. The next substantive phase is transaction bodies,
witnesses, auxiliary data and signing integration (P08). Hosted matrix results
are verified on the pull request separately from local results.

Final C-helper formatting uses explicit braces, matching cardano-c. After that
format-only change, all 264 ordinary tests and a focused Valgrind run covering
all 25 new domain tests pass with zero errors or lost bytes. A throwaway negative
control intentionally omitted a cardano-c buffer release; Valgrind still failed
with both direct and indirect losses and no suppressions, confirming that the
RTS exception does not match that native allocation stack.

### P08 transaction continuation

PR #14 is merged and its main-branch matrix passed. This batch implements typed
transaction bodies, outputs, resolved UTxO snapshots, witness and auxiliary data,
exact transaction/subtransaction envelopes, and scoped key/software-handler signing.
It also adds generic, Byron and pointer addresses needed by transaction outputs.
It does not complete providers, balancing, submission or all transaction inspection
conversions; the ledger retains these domain gaps explicitly.

### Complete output-address review

Reviewed cardano-api's AddressAny and StakeAddressReference API and source at https://cardano-api.cardano.intersectmbo.org/cardano-api/Cardano-Api-Address.html and its linked source. It distinguishes Byron/Shelley payment forms and models stake pointers explicitly. Reviewed the previously pinned Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9 GeniusYield.Types.Address source: GYAddress wraps AddressAny, converts to any supported era, serializes bytes/text and extracts payment authority. Byron examples and pointer conversion show why transaction outputs cannot be restricted to the already implemented base/enterprise forms.

Cometa adds a sum for generic Shelley, Byron and reward addresses, while retaining separate typed public families. Output construction does not imply ledger admission of a reward account. Byron uses validated root, attributes and kind with exact accepted address bytes; CBOR CRC32 and Base58 are pure. Unknown/duplicate attributes, incorrect tag/arity/checksum and trailing bytes are rejected rather than silently normalized. Encrypted path attributes are limited to 64 bytes; network magic is nonnegative through maxInt64, matching native signed storage. Native decoder accepts some malformed variants that the binding deliberately rejects. A new address from typed components has fresh minimal encoding; imported address bytes are preserved.

Native pin eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1: address/internals/pointer_addr_pack.c encodes and decodes uint32 despite uint64 stake_pointer.h fields. Pointer components are therefore bounded Word32 in this binding and malformed/overflowing/trailing encodings are rejected. Full uint64 native pointer support remains explicitly deferred; no silent truncation is exposed. Existing base/enterprise/reward semantics are retained. Byron encoding uses [tag24(bytes([root,attributes,type])),crc32(payload)], attributes1/2 contain nested CBOR bytes. Native Byron getters copy attributes and allocate the root hash; pointer credential getters retain. Test oracles release these obligations and reconstruct from typed constructor inputs.

Complete-address verification: test/CompleteAddress.hs and
cbits/complete_address_oracle.c add nine tests. All passed in the root integrated
run: all three Byron authority types, optional encrypted path including empty
normalization and64bytes, optional network magic0/maxInt64; key/script pointer
credentials across all16network tags and variable-width boundaries through
maxWord32; pinned Apache2 CIP19 Byron/pointer fixtures; generic reward dispatch;
nonminimal/indefinite outer Byron preservation; independently Python-zlib-CRC32
wrapped invalid inner payload fixtures reaching root/type/attribute/path/magic
validation; malformed checksums/Base58/truncation/trailing/overflow/nonminimal
pointers; repeated native scopes; original Hedgehog generated Byron/pointer values.
The C oracle reconstructs from newly allocated Byron root hash, copied attributes
and type or retained pointer credential plus copied network/stake pointer, then
compares fresh bytes and text. Both family-to-generic conversions allocate
independent native addresses, verified in actual implementation; all references
are released separately. C11 warnings, stock ClangFormat18, Ormolu and HLint pass.


# Transaction body API review

Reviewed actual pinned sources before choosing API:

* cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5, https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs : TxBodyContent (lines 865-925), defaults, separate TxOutDatum alternatives and makeTransactionBody checks. Common workflow assembles body content from typed inputs/outputs plus optional fields, then validates/builds and signs. Adopt explicit field meaning and absence, total defaults; do not reproduce era-indexed BuildTx/ViewTx classes or bundle witnesses in body.
* Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9 https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/TxOut.hs : GYTxOut owns address, value, datum choice and reference script; txOutToApi selects inline versus supplemental. Adopt explicit datum alternatives and immutable owned values. Cometa does not silently change inline choice and cannot infer supplemental witness data from a hash.
* Same Atlas pin, Types/TxOutRef.hs: reference is txid plus index with Eq/Ord; adopt equivalent pure domain identity while preserving native uint64 indices rather than narrowing to ledger Word16.
* Same Atlas pin, Types/TxBody.hs lines 86-165: signGYTxBody, appendWitnessGYTx, unsignedTx and CBOR import/export workflow. Atlas explicitly warns body CBOR is API serialization, not ledger transaction_body. Cometa deliberately exports exact ledger-body CBOR, keeps standalone immutable semantic values and an exact encoding wrapper, and performs hash IO at existing native Blake2b boundary. Imported nonminimal CBOR remains unchanged until caller deliberately reassembles semantic data.

Concrete Cometa caller: validate transaction id/address/positive value once; assemble Input, Datum, Output; create body with inputs/outputs/fee and typed optional fields; encode for storage, reload via decodeCbor; inspect fields; hash exact EncodedBody in IO; assemble envelope and sign through separate workflow. Expected invalid input shares Either Error. No native pointers persist.

Native baseline eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1 transaction_body.c supports keys 0,1,2,3,4,5,6,7,8,9,11,13-27. Dijkstra keys23-27 are typed nested subtransactions, credential->optional datum, reward->coin, reward->balance interval, and starting balance intervals. Subtransaction bodies omit 2,6,13,16,17,23,27. Guard key14 accepts legacy bare key hashes and credential-form guards; fresh output chooses credential form if any script guard appears. Maps reject repeated keys rather than mirror native overwriting. Exact original bytes retain presence/tag/map ordering. Native construction/hash/CBOR agreement are independent tests, with reconstruction cache explicitly cleared.


## Witness and auxiliary-data API evidence

Reviewed before designing public APIs:

* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Sign.hs. `makeShelleyKeyWitness'` computes the annotated body hash and assembles verification key/signature. `makeShelleyBootstrapWitness` derives Byron attributes from network/address and the extended public key. `addKeyWitnesses` replaces the ledger key/bootstrap sets via `Set.fromList`. The complete workflow constructs typed body, signs its exact annotated hash, assembles key witnesses, and makes a signed transaction while carrying scripts/data.
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Tx.hs. `GYTxWitness` wraps `AlonzoTxWits ConwayEra`, deriving Semigroup/Monoid; CIP30 examples decode wallet-returned CBOR and extract Shelley key witnesses through a ledger Set. `txWitFromHexBS` uses `decodeFullAnnotator`, retaining annotated encoding. https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Redeemer.hs wraps BuiltinData and converts to `HashableScriptData`; index/budget come from transaction assembly rather than the argument wrapper.

Cometa follows typed verification-key/signature reuse, indexed script argument/budget assembly, full decode boundaries and exact annotated identity. Differences: standalone codecs cover native V4 and guarding purpose6 beyond Atlas's Conway wrapper; they do not assert ledger-era validity. Purpose/index identifiers are unique; explicit errors replace left/right-biased overwrites. Witness merges reject differing signatures for one key and different argument/budget for one redeemer pointer. Identical additions are idempotent. There is deliberately no unconditional Semigroup because merge can conflict. Collections remain lists, preserving native order/duplicates; no casual conversion through Map/Set. Script order is grouped by serialized language fields on assembly. Existing exact field values remain unchanged for signature-only edits, and exact nested script/data encodings survive changed collection envelopes.

Complete workflow: validate external key/signature bytes once; construct indexed arguments with existing EncodedPlutusData and ExUnits; assemble Witnesses; import wallet CBOR into EncodedWitnesses; merge with explicit conflict handling; attach to a transaction whose body encoding remains exact; inspect public semantic fields or persist exact bytes. Auxiliary assembly combines optional metadata, optional native script list, and versioned Plutus scripts. It groups versions safely with total assembly. Hashing consumes full exact EncodedAuxiliaryData bytes through explicit IO Blake2b256, never metadata alone. Scripts and present/absent empty fields participate in hash identity. The standalone typed example demonstrates data and metadata composition; envelope agent covers signing workflow.

## Native audit

Pin `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, `lib/src/witness_set/*.c`, `lib/src/auxiliary_data/auxiliary_data.c`, corresponding public headers/tests.

Witness map fields0key,1native,2bootstrap,3PlutusV1,4data,5redeemers,6V2,7V3,8V4. Fresh native witness map omits empty collections. Native collections preserve insertion order; vkey/bootstrap fresh encoders omit earlier identical key/signature witnesses while imported collections preserve duplicates. Cometa's typed fresh lists deliberately preserve explicit duplicates, equivalent to importing the sequence; merge avoids adding repeated identical elements. This observable difference is documented rather than silently dropping elements. Redeemer native list sorts by purpose/index; native decoder rejects duplicates, latest map form is fresh output, historical array accepted on input. Purposes0..6 include Guarding; index unsigned64. Native vkey/bootstrap assembly does not verify signatures; typed Haskell likewise validates only lengths. Bootstrap chain code exactly32bytes follows native constructor check. Attributes remain opaque serialized bytes.

Auxiliary input supports plain metadata map, historical array metadata/native scripts and tag259 map0metadata,1native,2V1,3V2,4V3,5V4. Tagged decoder rejects unknown/duplicate fields; exact wrapper preserves legacy/nonminimal/indefinite bytes independently from normalized semantic assembly. Empty optional auxiliary lists remain distinguishable. Script payload codecs preserve their existing exact bytes.

All native witness/auxiliary object getters used by oracle retain output references, confirmed in implementations; key/signature/bootstrap buffer/redeemer data/exunits outputs likewise retained. Scalar getters borrow values; child objects remain live until fresh constructor retains them. Oracle releases every local obligation once, never tests pointer nullness after unref to infer ownership, and never reuses released loop locals. Fresh outer witness/auxiliary envelopes reconstruct through getters/new/set; key/bootstrap/redeemer members reconstruct through their semantic fields/new. Script/data/metadata leaf serialization is reused as exact identity-bearing payloads already independently tested in their domains. No outer source CBOR cache is forwarded.

## Verification scope

`test/TransactionWitnesses.hs` covers native reconstruction of typed key/bootstrap/all7redeemer purposes/full witness map/all4Plutus versions/auxiliary map; imported Apache2 corpus key/bootstrap and four auxiliary variants including V4 and both historical formats; independently computed Python hashlib Blake2b256 empty auxiliary golden; exact nested nonminimal datum through add/remove signatures; identity/idempotence/associativity/disjoint merges and signature/redeemer conflicts; duplicate/unknown keys, malformed lengths, truncation/trailing and partial native failure cleanup;100 repeated scopes; original Hedgehog full Word64/Word8 typed roundtrips/native reconstruction. C oracle compiles warning-clean against stock pinned headers; Ormolu0.8.0.2 and HLint3.8 run locally. Root coordinates actual cabal tests/examples/Haddock/Valgrind; no claim of executed full suite here.

A standalone C harness additionally links against the configured native scratch
build and confirms fresh key, bootstrap, redeemer, auxiliary and V4 auxiliary
corpus reconstruction (all five comparisons true). Per-collection `get_use_tag`
and `set_use_tag` conveniences remain explicitly pending in the ledger: imported
field bytes preserve tagged/untagged policy and fresh assembly uses tag258, but
there is no direct public per-collection toggle. These are not counted as
implemented through generic reference-count plumbing.

Integrated tests exposed the native redeemer fresh encoder's explicit UINT32_MAX
index restriction (both redeemer.c and redeemer_list.c), despite uint64 constructor,
getter and imported cached storage. The public index is consequently Word32;
arguments and both execution budget components still cover full Word64. Larger
imported indices fail rather than constructing values which cannot be freshly
serialized natively. Regression fixtures exercise 2^32 rejection. Native cached
forwarding of larger indices is deliberately not exposed as an editable domain
value. Public selectors of abstract Witnesses/AuxiliaryData are ordinary observer
functions over private record labels, so record updates cannot desynchronize exact
field caches or insert a script under the wrong version.

Merge retains existing fields based on merged typed equality, rather than raw
incoming equality. A regression imports an indefinite map/nonminimal key with
indefinite untagged key collection and witness array, then merges the identical
fresh key/signature and asserts the full original bytes remain unchanged. Script,
datum and redeemer-argument equality continues to include exact encoded payloads.


### P08 envelope, exact identity and signing review

Reviewed actual source before choosing the public envelope/signing workflow:

* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, [Cardano.Api.Tx.Internal.Sign](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Sign.hs), specifically `signShelleyTransaction`, `makeSignedTransaction`, `getTxBody`, `getTxWitnesses`, `hashTxBody`, `makeShelleyKeyWitnessFromHash` and `addKeyWitnesses`. A body and separate keys/witnesses assemble a transaction. HashAnnotated extracts the body's original annotated hash; incremental additions merge existing key/bootstrap witnesses. The same hash/witness operations apply to top/sub transaction levels. Cometa follows exact body-hash signing and incremental witness assembly, but runtime-independent Haskell-owned snapshots avoid era-witness/class machinery and keep unaudited native crypto in IO.
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, [GeniusYield.Types.Tx](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Tx.hs), witness-set wrapper, CBOR import and actual CIP-30 `api.signTx` example. An external wallet returns a witness-set CBOR payload to attach rather than a replacement transaction body. Cometa's `Tx.addWitnesses` merges an `EncodedWitnesses` payload while retaining exact body/wrapper bytes; conflicting signatures for the same public key fail instead of choosing silently.
* Atlas same pin, [GeniusYield.TxBuilder.Class](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs), `GYTxMonad.signTxBody`, `signTxBodyImpl`, `signTxBodyWithStakeImpl`, and `signAndSubmitConfirmed`. Caller builds a body, signs with private keys held in a closure, then separately submits. Cometa keeps scoped keys and one Either/ExceptT boundary; this batch implements offline signing/inspection, not submission or network checks.

Native pin `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`: audited `transaction/transaction.c`, `transaction/sub_transaction.c`, `key_handlers/secure_key_handler.c`, `key_handlers/software_secure_key_handler.c`, `key_handlers/derivation_path.h`, `witness_set/vkey_witness_set.c`, and `transaction_builder/balancing/internals/unique_signers.c`.

Contracts implemented:

* Public decode is pure typed schema validation of exactly one complete CBOR item. It accepts historical `[body,witnesses,aux|null]`, mempool `[body,witnesses,isValid,aux|null]` and block `[body,witnesses,aux|null,isValid]`, definite or indefinite. `decodeWithByteSpan` captures original slices instead of normalizing through a CBOR AST. Unknown/malformed component schemas and trailing bytes fail.
* Transaction equality compares exact complete encoding. Body equality is the documented semantic comparison, retaining identity-sensitive embedded encodings. `setBody` with an equal Body is an exact no-op, including every signature and wrapper byte. Changed bodies drop only outer verification/bootstrap signatures. Fee edits use the body's private validated field-slice helper; all other field payload bytes survive.
* Witness-only edits retain exact body and outer prefix/suffix. An unchanged partial merge is exact and idempotent. Nested scripts/data retain the witness module's exact field contract. Sub-transactions retain their own body, witnesses, auxiliary data and array framing; editing enclosing fees clears only outer key signatures.
* Hashing uses exact body bytes through native BLAKE2b-256. Scoped SigningKey signing signs that digest, not full-envelope CBOR. The independent direct native test oracle decodes the transaction, obtains native top/sub ID, and signs it using direct native Ed25519 constructors; tests compare public key and signature bytes and also verify all retained signatures with the pre-existing native oracle.
* Fresh `assemble` accepts validated encoded components and creates a true mempool frame (sub uses three fields). Auxiliary replacement does not update the body's auxiliary hash; this restriction is explicit. Script validity changes preserve identity/signatures; historical false claims explicitly promote to mempool framing, preserving definite/indefinite width and component bytes.
* Software Ed25519 and BIP32 top/sub signing returns partial encoded witnesses. BIP32 takes NonEmpty validated derivation paths; request once, derive/sign all paths, deduplicate duplicate keys according to native vkey-set behavior. No secret export. Existing Handler nominal role distinguishes capabilities. Existing scoped withOperation lock, callback worker/rooting, exception propagation and cancellation join are reused without alternate runtime lifecycle.
* C adapter borrows handler/input/flat paths; owns all decoded transaction, path, vkey, writer and witness references per call; releases partial outputs on failure. Success transfers one public cardano_buffer copied and wiped/released in the existing lock scope. All callback-capable imports are safe/non-interruptible; no arbitrary unsafePerformIO.

Meaningful domain omissions remain explicit: transaction find_* indexing and get_unique_signers move to P12 contextual building. The latter is resolved-input/collateral/certificate/voter authority analysis, not simply existing witness keys. CIP-116 transaction/subtransaction JSON is an explicit follow-up; no P08 completion claim should hide these items as ownership plumbing.

Evidence: test/PublicTransaction.hs reuses all pinned signed fixtures from Fixtures.Transaction and TRANSACTIONS.md, and generates all three frame orders with definite, indefinite and nonminimal definite headers. Tests check independent hashes/native signature bytes, exact no-op edits, signature invalidation, untouched witness payloads, optional auxiliary assembly/replacement, script-claim edits, input immutability, wrong/invalid passwords, closed keys/handlers, overlap/reentry, synchronous callback exceptions, cancellation/finalizer join and same-handler recovery, normal/extended keys, typed BIP32 paths and nested subtransaction identity. Existing fixture notices/license provenance remain unchanged; no new upstream code copied. The oracle adapter is original Apache-2.0 project code.

Local checks for this contribution: Ormolu 0.8.0.2; HLint 3.8 no hints; stock ClangFormat18 with project style/InsertBraces; C syntax -Wall -Wextra against pinned native headers passes. Root coordinates Cabal builds/tests/Haddock/guide/Valgrind; record their final results separately.


Internal refcount and diagnostic entries that were pending remain pending;
immutable values do not imply a one-to-one public refcount API. The ledger records
2,131 implemented/adapted entries out of 3,881. Contextual required-authority
analysis, transaction indexing, CIP-116 JSON inspection and explicit collection-tag
controls remain visible follow-ups alongside P09 provider/evaluator/selector contracts.

#### Local integrated verification

The final tree passes all 304 tests with warnings as errors (8.01 seconds).
A fresh source-distribution consumer builds all components and passes the same
304 tests; all 22 executable examples run. Handler-capability and credential-role
compile-fail controls pass. Every public module has complete Haddock declaration
coverage. Ormolu, HLint, ClangFormat 18, package checks, the 3,881-entry inventory,
and strict Sphinx HTML/link checks pass.

The aggregate Valgrind run passes its 303-test snapshot in 289.19 seconds with
zero errors, zero definitely/indirectly/possibly lost bytes and zero suppressed
allocations. The final added body-ordering, pinned-hash and witness regression
assertions also pass under a focused Valgrind run with zero errors or lost bytes.
No native dependency change or new suppression was needed. Hosted compiler/OS
results are checked on the PR separately from this local evidence.


### P09 runtime extension points

#### API research (2026-11-06)

The following source review informed the implemented contracts. Native source was audited at `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, together with the existing private provider/callback prototype.

#### Primary sources and what their callers do

1. **cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`**:
   * [Query/Internal/Convenience.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Query/Internal/Convenience.hs), `executeQueryAnyMode`, `executeQueryCardanoMode`, `queryStateForBalancedTx`; [Query/Internal/Expr.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Query/Internal/Expr.hs), `queryUtxo`, `queryProtocolParameters`, `queryEraHistory`, `querySystemStart`. A local-state query acquires node state, reports acquisition/version/era errors, and queries the complete context needed for balancing. The convenience boundary collapses nested protocol errors into one `ExceptT QueryConvenienceError IO` result. Cometa should retain structured errors and offer a standard Either/ExceptT boundary, without importing era/typeclass ceremony that its runtime schema does not provide. Separate provider requests cannot promise the same acquired ledger snapshot: freshness/consistency must be explicit.
   * [Tx/Internal/Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs), `evaluateTransactionExecutionUnits` (717+), `evaluateTransactionExecutionUnitsShelley`, auto-balance caller (1116+), `substituteExecutionUnits`. Evaluation receives system start, epoch history, protocol parameters, resolved UTxOs and body; returns a map keyed by script witness index, with per-script failure or `(logs, execution units)`. Auto-balance evaluates, checks failures, substitutes budgets, then calculates fees. Evaluation is distinct from balancing and signing. Cometa's native evaluator has an all-or-error result and returns full redeemers, so copying cardano-api's partial-success/log API would promise information the native ABI does not supply.
2. **Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`**:
   * [Types/Providers.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Providers.hs), `GYProviders`, `GYGetParameters`, `GYQueryUTxO`, single/batch query defaults, parameter caching note. This is an idiomatic record of IO functions, including optional accelerated operations represented by `Maybe`; basic single queries can supply batch defaults. Missing single UTxO/datum uses `Maybe`; batch lookup omits absent refs. Caches use exception-safe `modifyMVar` around check/fetch/update. Several optional higher-level fields deliberately remain lazy/undefined in some providers; Cometa should use explicit unsupported capabilities rather than bottom-valued record fields.
   * [Transaction/CoinSelection.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Transaction/CoinSelection.hs), `GYCoinSelectionEnv`, `selectInputs`, strategy ADT; [tests/GeniusYield/Test/CoinSelection.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/tests/GeniusYield/Test/CoinSelection.hs), property caller. Inputs include existing selections, candidate wallet UTxOs, payments, mint, extra Ada, min-Ada assessor and value-size limits. `ExceptT` composes selection failure with seeded randomness; tests assert eligible inputs, coverage and token change rather than a particular random choice. Atlas's result contains *additional* inputs, and its algorithm leaves final Ada reconciliation to the balancer. Cometa must not copy that result contract: native selectors return the *whole* selection, remaining candidates and locally balanced change.
   * [TxBuilder/Class.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs), `signTxBodyImpl`, `signAndSubmitConfirmed`. Keys stay in a signing closure; build, sign and submit are separate steps. Existing Cometa signing helpers naturally supply such a closure without private-key export.
3. **Lucid Evolution `8db7d3ce7cf81eea7a6c6c11bb182f1a5232b0a3`** (current main pinned during this review): [packages/core-types/src/types.ts](https://github.com/Anastasia-Labs/lucid-evolution/blob/8db7d3ce7cf81eea7a6c6c11bb182f1a5232b0a3/packages/core-types/src/types.ts), `Provider` (29+). This is TypeScript, not evidence for Haskell syntax. Its useful caller contract is a small asynchronous provider interface: protocol parameters, UTxOs by address/asset/reference, datum, delegation, evaluate with additional UTxOs, submit, await. Optional fast paths/status queries are explicit optional methods. Cometa should preserve its separation of provider/evaluation/signing responsibilities, while using typed validated values, `IO (Either Error a)`, explicit absence and documented timeout units instead of strings, JS numbers and rejected promises.

Sources were read, not merely located. Fresh copies are `/tmp/p09-api-{query,convenience,expr,fee}.hs`, `/tmp/p09-atlas-{select,select-types,select-tests}.hs`, `/tmp/p09-lucid-types.ts`; cached pinned Atlas provider/class sources are under `/tmp/cometa-haskell-review/`.

#### Proposed public contracts

Use records of functions, not a provider/signer class hierarchy or mandatory custom monad. Records describe user capabilities; native adapter handles, callback marshaling and close state stay private. Ordinary direct Haskell use need not acquire a C handle. A scoped native adapter is needed when those functions are passed to the native builder/evaluator, and must cover the entire native operation, including repeated callbacks.

* **Provider/query record:** protocol parameters; address UTxOs; address+asset UTxOs; resolve input refs; NFT lookup; datum lookup; reward balance; submit; confirmation; remote evaluation. Use public validated Address, Input, Utxo, AssetId, hash, Transaction and protocol values, not pointer or CBOR-only arguments. Result shape remains `IO (Either Error a)`. `Maybe` means an absent datum/UTxO, `[]` means an empty successful query, and `False` means not confirmed within the explicit millisecond timeout. Unsupported endpoint, transport failure and malformed response are errors, never absence. Submission is an explicit effect and never an automatic consequence of querying/evaluating. Optional endpoints must be explicit capabilities or total wrappers returning UnsupportedOperation, never undefined fields.
* **Evaluator record:** one `evaluateTransaction` function consuming an immutable exact Transaction plus additional resolved UTxOs, returning computed redeemers (or a checked budget map keyed by existing purpose/index). The function must not install budgets or change body/witness bytes implicitly. Reject duplicate/unknown result identifiers; if returning full redeemers, also verify that a callback did not change argument bytes under the guise of budget evaluation. No partial-success/log promise until backed by a richer result source. No scripts is a successful empty result. A bound top/sub evaluation target must be explicit when selecting the native evaluator; a sub evaluator still receives the complete enclosing top transaction.
* **Coin-selector record:** `selectCoins :: SelectionRequest -> IO (Either Error Selection)` (proposed names). A request owns validated preselected UTxOs, available UTxOs, authoritative target Value, optional output-shape hints, change Address and protocol parameters. Selection exposes selected UTxOs, remaining candidates and change outputs. The native law is `sum(selected) = target + sum(change)` componentwise, with all mandatory selections retained, no double spending, selected/remaining accounting and min-Ada-compliant change. Output hints are not the balance target. Fees, mint/deposit accounting and global balancing remain outside selection. Native/random selectors stay in IO; callers can supply deterministic fake closures. Validate container-level conflicts once at request/result boundaries; validated Output values already protect quantities.
* **Signer closure:** reuse `Transaction -> IO (Either Error EncodedWitnesses)` for partial signing, with existing scoped keys/Software handler captured by the closure. Compose `Tx.addWitnesses` explicitly. No raw key access and no arbitrary native signer hidden behind a pure function. A record can add a diagnostic name/capabilities only when a real caller needs them.

Proposed complete caller workflow, using standard `ExceptT` and one outer failure match:

1. Validate address, refs, target/payments and other external values once.
2. Query protocol parameters and available/resolved UTxOs through the provider record. State whether these are independent observations or one coherent snapshot.
3. Assemble/validate a SelectionRequest, invoke the injected selector, check its domain result laws, and assemble an unsigned transaction using the later builder layer.
4. Invoke the evaluator with that exact transaction and required resolved UTxOs; explicitly apply the returned budgets, recompute commitments/fees and finish balancing through the later builder layer. Iteration is deliberate and bounded, not a hidden one-pass guarantee.
5. Invoke a scoped signer closure, merge partial witnesses preserving exact body identity, then optionally call explicit provider submission/confirmation operations.

Complete balancing belongs to P10+. The compiled P09 examples demonstrate queries, selection, evaluation and scoped signing with deterministic fixtures, without network credentials.

#### Native contracts and lifetime risks

Primary native source links all use pin `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:

* [providers/provider_impl.h](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/include/cardano/providers/provider_impl.h) defines ten callbacks and a refcounted context; [providers/provider.c](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/src/providers/provider.c) copies the implementation struct, adopts its context without retaining, and unrefs context on final destruction. Callback inputs are borrowed for the synchronous call; successful pointer outputs transfer references. Wrapper calls do not initialize every output slot or clean arbitrary callback partial outputs: adapters must zero slots, retain/copy inputs, track transfer and release partial failures themselves.
* [evaluation/tx_evaluator_impl.h](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/include/cardano/transaction_builder/evaluation/tx_evaluator_impl.h) returns a redeemer list via output pointer; [tx_evaluator.c](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/src/transaction_builder/evaluation/tx_evaluator.c) likewise adopts context, calls synchronously, and copies its mutable error buffer on failure. [provider_tx_evaluator.c](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/src/transaction_builder/evaluation/provider_tx_evaluator.c) explicitly refs a provider before adopting it as evaluator context and releases that ref on constructor failure. Closing a public provider alias must not invalidate a retained evaluator.
* [evaluation/native_tx_evaluator.h](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/include/cardano/transaction_builder/evaluation/native_tx_evaluator.h) and corresponding source: copies slot configuration, retains cost models, binds protocol-major and optional sub index. Native evaluation checks every transaction level first, evaluates top and subs together under a shared budget, and returns fresh redeemers for the bound level. All spending/ref inputs must resolve from the additional UTxOs. Malformed/unavailable script is Decoding; phase-2 script failure is ScriptEvaluationFailure, with native diagnostic. Returned budgets are not installed in the input transaction. Slot time and slot length are unsigned milliseconds; slot length requires positive validation. This constructor's explicit VM behavior belongs to P11 coverage even when the injectable contract is P09.
* [coin_selection/coin_selection_request.h](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/include/cardano/transaction_builder/coin_selection/coin_selection_request.h), [coin_selector_impl.h](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/include/cardano/transaction_builder/coin_selection/coin_selector_impl.h), [coin_selector.c](https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/src/transaction_builder/coin_selection/coin_selector.c): all request pointers are borrowed until call return, required fields checked before callback, three returned collections owned by caller. The selector context is adopted, not retained. A callback may allocate one or two outputs and fail before the third: cleanup must account for each separately.

Common risks: native reference counts and error-message buffers are not safe concurrent shared mutation. Use an operation lock or isolated per-operation native objects; aliases share the lock. Root every StablePtr/FunPtr until final native context destruction, not merely the end of a user continuation. Retain operation owners while C may call back. Use safe callback-capable imports, never unwind Haskell exceptions through C, and rethrow callback exceptions after safe unwind. Cancellation must join C and callback workers before releasing buffers/context; timeout alone does not stop C. Force callback result traversal/encoding inside the protected worker before transferring ownership—WHNF of `Right [Utxo]` is insufficient. Native builder rebalance may call a provider/evaluator/selector repeatedly, so registrations live through its final cleanup. Existing private Cometa provider/Callback machinery already tests adopted context finalization, retained aliases, exception propagation, cancellation and same-provider reentry; extend its invariants instead of inventing another lifecycle.



# P09 selection and complete protocol snapshot review

Reviewed before API implementation at native eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1 and Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9. Prior consolidated source research is /tmp/cometa-p09-api-research.md.

Atlas actual caller source: https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Transaction/CoinSelection.hs , GYCoinSelectionEnv lines45-63, selectInputs lines74-90 and146-225. Existing inputs are mandatory; own UTxOs can overlap and fromIndexPair removes preexisting refs. Output shapes, mint, source/sink Ada, min-Ada assessor and maximum value size belong to its balancing environment. Atlas returns *additional* inputs after removing existing refs, plus token change; final Ada reconciliation belongs to the balancer. Cometa instead follows native's full selected/remaining/change result and authoritative target equation, without claiming whole-transaction balance or a strategy implementation. Atlas property caller source /tmp/p09-atlas-select-tests.hs was reviewed for invariant tests rather than identical randomized choices. Haskell record injection follows the provider/capability record approach rather than adding a selection typeclass.

Native sources audited:
* lib/include/cardano/transaction_builder/coin_selection/{coin_selection_request,coin_selector_impl,coin_selector}.h and lib/src/transaction_builder/coin_selection/coin_selector.c. The native wrapper validates required fields, invokes synchronously, adopts impl.context, and transfers three result list references. It does not initialize output slots or clean arbitrary partial callback outputs. Adapter initializes every slot and releases partially decoded outputs on all failures.
* internals/large_first_coin_selector.c lines127-185 and common/utxo_list.c remove: preselected values are appended to the complete selection; equal values are removed from available if present. Removing absent values succeeds. Therefore preselected may be disjoint or identically overlap available. Conflicting snapshots/duplicates are rejected at Haskell request boundary so one reference never silently denotes two values. The native property corpus constructs disjoint mandatory/candidate pools; Cometa tests also explicit identical overlap and conflicts.
* lib/src/transaction_builder/fee.c cardano_compute_min_ada_required: computes serialized output+160-byte overhead, iterates the required coin encoding width. The wrapper uses the actual utility and rejects an excessive coins-per-byte multiplication bound before native unsigned wraparound. No fee or global-balancer calculation is claimed.
* lib/src/protocol_params/protocol_parameters.c and protocol_param_update.c getters/setters. Required 14 base fields are demanded when decoding a complete Haskell snapshot. All scalar and typed object fields use native typed setters/getters; max-value-size full setter is int64 while sparse representation is uint64, so values above INT64_MAX are rejected at native materialization, never narrowed or bypassed. Pointer getters retain references; object setters retain independently. Peras bootstrap getter borrows a scalar pointer, used only within full-owner lifetime. Nullable leverage getter retains if nonnull.

Critical native availability limit: full parameter scalar fields have no presence bits and initialize to zero; optional nullable leverage NULL does not distinguish unavailable from explicitly unbounded. A known-origin optional snapshot template therefore controls availability while values always come from actual native getters. A native-origin export without template emits actual native scalar getter values as present, omits unavailable optional pointer groups, and emits explicit null for unbounded/unset nullable fields. A native-origin zero positive-only reference-script stride is omitted as an unset/unrepresentable sentinel, never replaced with an invented positive value; known-origin explicitly present zero is rejected. Required missing pointer groups fail. This does not invent semantic defaults or promise recovery of absence information the native type never stored. Tests distinguish known-origin exact presence from native-origin materialized presence, and mutate native fee values after import to establish that export reads actual getters instead of echoing the original template.

Caller workflow: query/receive Parameters and resolved typed UTxOs; validate SelectionOptions once; supply Selector selectCoins closure; invoke public select directly to check contextual laws and native minimum Ada; then pass selection to later transaction balancing. No standalone callback roundtrip is imposed. Private withSelector/invoke adapter demonstrates actual native callback dispatch and is reusable by future native builder scopes. Shared Runtime gate owns callback exception containment, cancellation join and registration lifetime; native selector context independently retains the runtime until selector destruction.

Selection validation: unique refs in each input/output list, nonconflicting identical overlap; chosen subset of eligible union with exact snapshots; all mandatory refs included; remaining exactly available minus chosen; selected value = authoritative target + change componentwise; all change at requested address; actual native min-Ada per output. Order is retained but does not affect accounting. Target includes externally assessed fees/deposits; output hints cannot replace it. Chain-state spendability, strategy algorithms, max-value-size splitting and global balancing remain outside P09.


#### Evaluation and signer API evidence

Reviewed actual sources before design, at the task's pinned revisions:

* cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs (`evaluateTransactionExecutionUnits`717+, per-purpose result map; auto-balance caller and substituteExecutionUnits). The caller obtains protocol context/resolved UTxOs, evaluates each script, checks script errors, substitutes units and computes fees. Evaluation and mutation remain distinct. Per-script partial errors/logs are possible in that richer ledger API but unavailable in native evaluator ABI, so Cometa promises all-or-error budget results only.
* Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`, https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs (`signTxBodyImpl`290+, `signAndSubmitConfirmed`405+). A signing action obtains a scoped signing capability, signs a completed body and leaves submission explicit. Cometa's Signer captures existing scoped Ed25519/Software closures and returns partial EncodedWitnesses; addWitnesses remains explicit. No class hierarchy or key export is needed.
* Native `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, https://github.com/Biglup/cardano-c/blob/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/lib/include/cardano/transaction_builder/evaluation/tx_evaluator_impl.h and corresponding lib/src/.../tx_evaluator.c, plus provider_tx_evaluator.c and native_tx_evaluator.c. Impl context is adopted without ref by constructor, released at final evaluator destruction; evaluate callback borrows tx/additional list and transfers redeemer list on success. Wrapper does not sanitize partial outputs. Provider-backed evaluator retains provider explicitly before adopting context. Native VM creation binds a level but evaluates complete transaction context; its completeness/phase2/slot/cost-model behavior is P11, not part of injectable P09 completion.

#### Public caller contract and deliberate differences

`Evaluator {evaluateTransaction :: Target -> Transaction -> [Utxo] -> IO(Either Error Budgets)}` exposes ordinary IO injection. `evaluate` is checked direct Haskell dispatch, with no forced C roundtrip. Target is TopLevel or SubTransaction Word64, checked by bounded-list traversal before any Int conversion. Complete enclosing Tx is always supplied. Resolution duplicates are rejected, but all-input completeness is evaluator-specific: provider-backed evaluation may fetch other inputs and treats supplied UTxOs as additional context.

`Budgets` is an abstract sorted unique list of `(RedeemerId Purpose Word32, ExUnits)`. `mkBudgets` rejects duplicates rather than overwriting through Map; identifiers are structurally unique, so their checked sorted map use is lawful. `evaluate` verifies complete identifier coverage for the selected target. The result has no script argument fields, so it cannot silently replace arguments. Native adaptation reconstructs full redeemers from original exact EncodedPlutusData arguments plus returned units, then validates returned IDs and exact arguments again after native dispatch. No budget installation/body/witness/cache mutation is performed. No unconditional Semigroup/Monoid exists for failing/conflicting capabilities.

`Signer {signTransaction :: Transaction -> IO(Either Error EncodedWitnesses)}` composes scoped Ed25519/Software functions. ed25519 signs the exact body hash and returns one verification witness; software/bip32 capture typed handlers and nonempty paths. Scope checks remain enforced by existing key/handler operations; no private export, submission, fee change or automatic witness merge occurs.

Workflow example examples/Evaluation.hs validates/assembles transaction -> invokes deterministic fake evaluator -> captures scoped signer -> returns partial witnesses -> explicitly merges, all through one ExceptT match. It does not pretend to execute a VM or balance a transaction. The public guide explains target, units, absence, completeness, expected errors and scope behavior in domain terms.

#### Native adapter ownership and lifecycle

cbits/cometa_evaluation.c creates a real cardano_tx_evaluator_t, refs runtime context before native constructor adopts it, and releases that extra obligation on constructor failure. Callback inputs are borrowed throughout synchronous native call. All indexed UTxO getters retain children, released once each after serialization. Request/reply writers/readers/buffers and partial redeemer outputs are independently initialized null and unref'd on every exit. Reply parse failures—including a valid allocated list followed by trailing bytes—release that list before failure. Native evaluator run uses a retained alias across repeated native dispatch, then releases final alias after callbacks unwind. No public close handles exist; private runtime scopes join callback/native workers before registration destruction. Shared Runtime controls exception/lazy-result forcing, expected Error identity, async cancellation, reentry and group activation; no separate callback lifecycle implementation duplicates it.

Direct evaluation receives the original exact Haskell Tx. The private generic native adapter necessarily snapshots cardano_transaction_to_cbor; native serialization can normalize the outer definite/indefinite array header, while preserving exact body/witness/script/data child bytes. Inputs remain immutable. This implementation detail is recorded internally; it does not change the direct public dispatch contract.

#### Tests and coverage boundaries

`test/Evaluation.hs`: direct vs actual C dispatch correspondence for all7purposes, explicit subtarget/maxWord32index, unchanged original transaction/budgets and exact nonminimal arguments; empty scripts; duplicate/missing/unknown budget IDs; changed exact argument rejection; invalid targets/duplicate resolution rejected before callback; repeated real C callbacks/retained aliases/GC/root-registration baseline; original expected Error longer than C diagnostic buffer; user IO exception and lazy-poison result; same-runtime reentry; cancellation joins callback cleanup and permits reuse; partial transaction/UTxO/redeemer parsing and trailing reply; Ed25519/Software/BIP32 signer scope composition and closed key; original Hedgehog fullWord32 index/fullWord64 units native roundtrips. No imported execution vectors or live network/keys. Integrated validation is recorded below.

The actual native provider evaluator factory is additionally adapted privately:
cometa_evaluation_run_provider creates a real provider using the shared provider
runtime bridge, calls cardano_tx_evaluator_from_provider, releases its local
provider construction reference before any evaluation, then dispatches repeated
callbacks through the retained evaluator. Final evaluator destruction releases
its retained provider, which releases the adopted runtime context. The test
compares three provider-backed native dispatch results against direct evaluation.
This factory is now marked adapted rather than deferred in the ledger; no public
native resource handles are introduced.

The native correspondence test also supplies a nonempty typed resolved UTxO and
an indefinite transaction envelope, saves the callback's owned typed snapshot,
and inspects it after native owners and registrations have been released. Exact
body/witness bytes and resolved semantic outputs agree, while the original full
indefinite transaction remains byte-identical. Native diagnostic-name inspection
remains explicitly pending in the ledger; assigning the private factory name is
not counted as implementing a user name capability.


#### Integrated decisions and private adapter tests

Providers expose typed records with explicit name/network magic and an
`unavailable` constructor for partial implementations. Missing single values use
Maybe, batch resolution omits missing references, and backend failures stay Left.
Direct Haskell calls do not cross the native boundary. Evaluation returns checked
budgets without replacing redeemer arguments; selection validates complete input
accounting and minimum Ada. Native algorithms, VM construction, balancing and
connected Blockfrost access remain later phases.

The private shared runtime deduplicates operation gates, retains each participating
handle and activates all callback controls before entering C. Expected callback
errors are recovered only when the native operation fails; a native retry may
handle a previous failure successfully. Exceptions always unwind through C before
being rethrown. Group cancellation sends requests concurrently, then joins both
the native worker and every cancellation sender. This avoids deadlocking a masked
callback whose cleanup depends on another callback's cancellation. The regression
uses two actual native threads (pthreads or Windows threads), not mocked dispatch.

The public library keeps its existing package and Haddock layout. Typed adapters
remain hidden modules. The additional `cometa-runtime-test` component compiles the
same source tree directly against the private core sublibrary, allowing lifecycle
tests without exposing handles in the public API. The existing suite and all
examples still consume the installed public library. This deliberately recompiles
sources; it follows Cabal's documented source-directory sharing model and avoids
mixing home-module and installed-package type identities. Lifecycle-counter tests
run sequentially. CI runs both suites under Valgrind and compiles/runs all three
new offline examples.

Local integrated evidence: 304 public-package tests and 46 runtime tests pass;
all 25 offline examples run, and a fresh source-distribution consumer builds and
passes both suites. Public declarations have complete Haddock coverage; strict
Sphinx HTML and link checks pass. Both complete test suites pass Valgrind with
zero errors, zero definitely/indirectly/possibly lost bytes and zero suppressions.
External compile checks confirm all four typed native adapters remain hidden.
Formatter, lint, package and native-inventory checks pass. Hosted compiler/platform
results are tracked on the PR separately from this local evidence.


### P10 transaction-building workflows

The preceding runtime PR passed the hosted compiler/platform matrix, formatting,
strict documentation and Read the Docs. This increment adds native selectors,
standalone cost calculations and ordinary transaction-building workflows to that
merged baseline. Deferred redeemers, advanced VM APIs, governance proposal
conveniences and Dijkstra batching remain subsequent work.

#### API evidence

Reviewed cardano-api at `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`, especially
[`makeTransactionBodyAutoBalance`](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs).
Its caller supplies resolved inputs, protocol context, a body and a change
address; evaluation, witness estimates, fees and change produce a balanced body.
Cometa follows that explicit workflow with Haskell-owned inputs and one expected
error boundary. Native balancing stays in IO; no additional purity exception is
introduced.

Reviewed Atlas at `c3adfb416242ea25a244bfaa1614213eecdc55d9`:

- [`TxBuilder.Class`](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs)
  and its skeleton tests demonstrate composable requirements and separate signing.
- [`Transaction.CoinSelection`](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Transaction/CoinSelection.hs)
  and selection tests inform strategy selection, accounting and eligibility checks.
- [`Types.SlotConfig`](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/SlotConfig.hs)
  and its tests distinguish slot starts and enclosing slots. Atlas supports era
  history; Cometa's current native interface accepts a single constant-duration
  schedule. The public contract explicitly excludes earlier periods.

The native audit used the pinned revision
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`: builder state/configuration/build/mint,
transaction balancing, largest-first and random-improve implementations, change
construction and splitting, fee and implicit-coin utilities, script-data hashing,
value arithmetic, native evaluator limits, slot configuration and time conversion.

#### Public contracts

`Plan` is an abstract sequence with lawful associative composition and identity.
Interpretation preserves payment order and multiplicity, combines mint quantities
per asset, omits net-zero minting, coalesces compatible idempotent requirements,
and intersects validity bounds. Incompatible inputs, metadata or withdrawals fail
at the build boundary. Common key spends, minting, certificates and withdrawals
have simple constructors; named variants accept script arguments.

`Builder.Config` supplies protocol parameters, slot configuration, change and
wallet/collateral snapshots. Optional selector and evaluator records reuse P09.
Providers remain upstream of this operation, or inside an injected evaluator;
the native builder has no provider setter. Building returns an unsigned owned
transaction and performs no implicit signing or submission. The native defaults
are random-improve selection and native evaluation, as established from source.

Native selectors implement the existing `Selector` record. Seeded calls restart
from the seed, allowing deterministic replay for one library version. Unseeded
random-improve obtains fresh entropy per call. `Minimal` and `Optimal` preserve
the authoritative target while choosing different input/change distributions.
Output hints affect change shape, not the accounting equation.

`SlotConfig` is immutable and validated. Conversions are pure, use Integer
intermediates and return checked Word64 values in Unix milliseconds. Zero duration,
earlier periods and overflow fail explicitly. Presets are checked against native
constants. Network-magic helpers that use seconds remain separate ledger gaps.

Standalone utilities calculate minimum Ada, linear/full fees, reference-script
fees, script-data commitments and outer/subtransaction deposit/refund accounting.
Full fee calculation requires resolved spending and reference inputs, not only
references. Native pricing deduplicates within a body and charges occurrences in
different bodies separately. Script-data hashing preserves exact redeemer/datum
encodings and requires callers to supply the relevant language views.

#### Native corrections and safety

Native random-improve concatenates mandatory and available pools. The adapters
remove mandatory references from candidates, preserving the public overlap
contract. Builder wallet/collateral lists reject duplicate references and check
conflicting snapshots across the plan and configuration.

Native mint setters replace quantities. Plan interpretation therefore sums each
asset in Integer before emitting one bounded setter. Repeated payments remain
separate outputs; they are never removed by general-purpose deduplication.

Balancing can subtract withdrawals, refunds and minted assets from the funding
target. P09's nonnegative target restriction was too narrow. Requests now accept
signed 64-bit target components with the unchanged conservation equation:
selected value equals target plus nonnegative change. Private target snapshots use
signed coin and a signed multiasset map because ledger Value CBOR uses unsigned
coin. Ordinary transaction output encodings remain unchanged.

Native balance additions and witness-fee intermediates need stronger bounds than
individual field validation. Preflight uses Integer to bound aggregate sources,
sinks, minting, deposits, refunds, witness estimates, execution costs and reference
script charges. The serialized-size upper bound includes change that repeats
incidental assets across payment hints. Oversized requests fail before balancing.
Injected evaluation budgets are checked against protocol limits. Native execution
fee bounds use the audited fixed memory/CPU ceilings; returned transactions are
also checked against protocol budget limits.

Final size validation uses the native distinct required-signing-key analysis,
not the number of selected inputs. This avoids rejecting many inputs controlled
by one key. Bootstrap witnesses retain a conservative attribute-size allowance.
Explicit validity endpoints must fit the supplied slot schedule.

#### Ownership and evidence

Every build owns a fresh native builder, decoded snapshots and callback adapters.
Setters retain their inputs; local obligations are released independently. The
shared runtime joins callbacks and native work on cancellation before releasing
registrations. Results and native diagnostics are copied before owner cleanup.
Native selectors similarly scope their request, selector and three result lists;
standalone utilities release partial decoded owners and result buffers on failure.

Tests use typed Haskell fixtures and actual native dispatch. Selector tests check
accounting, shape, deterministic replay, size splitting, signed surplus targets,
mandatory overlap, arithmetic failure, concurrent use and cleanup. Slot tests
compare native constants and both conversion directions, including boundaries.
Utility tests independently calculate fees and tier rounding, cover spending
reference scripts and per-body pricing, and reuse the native Apache-2.0
`script_data_hash.cpp` datum-only hash vector. No funded-wallet data is included.

Builder tests cover repeated payments, additive minting, certificates, withdrawals,
metadata, scripts, validity intersections, surplus change, real selector/evaluator
callbacks, malformed VM failure, budget/size/amount limits and plan laws. The
injected evaluator fixture intentionally supplies budgets for a synthetic script;
it tests callback integration, not on-chain script validity. Lifecycle tests cover
success, failure, exceptions and cancellation. A 300-input shared-key regression
checks distinct-witness sizing.


#### Integrated validation

All 383 tests pass: 307 public-package tests and 76 runtime tests. A fresh source
archive builds all components and passes both suites. All 27 offline examples run,
and handler/credential role checks pass. The complete runtime suite passes
Valgrind with zero errors, zero definitely/indirectly/possibly lost bytes and zero
suppressions. Public declarations have complete Haddock coverage; strict guide
HTML and link checks, Ormolu, HLint, ClangFormat, package and inventory checks pass.
Full public-suite Valgrind and hosted compiler/platform results are recorded on
the PR. No live-network or complete advanced-VM conformance claim is made here.

Standalone set-valued required-authority inspection remains pending in the native
ledger: using its native signer analysis internally for witness sizing does not
expose that entire public capability. Other outstanding building/evaluation and
Dijkstra operations retain their explicit pending entries.


### P11: native evaluation and deferred redeemers

#### Native evaluator API and source review

Established Haskell source inspected before API design: cardano-api commit
`5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`,
[Tx/Internal/Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs),
local snapshot `/tmp/p09-api-fee.hs`: evaluateTransactionExecutionUnits 721–775;
auto-balance caller 1100–1155. Caller obtains system start/era history/protocol
parameters/resolved UTxO/body, executes scripts, inspects indexed per-script
failures and logs, substitutes budgets explicitly, and computes fees. Cometa
preserves explicit context, identifier-keyed results and separate mutation;
its synchronous native ABI reports all-or-error, so partial successes/logs are
not invented. Native slot config is a constant-duration schedule, not ledger
epoch history. Minor protocol version does not enter the native constructor.

Reviewed pinned native source/header at `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:
`lib/include/cardano/transaction_builder/evaluation/native_tx_evaluator.h`,
`lib/src/transaction_builder/evaluation/native_tx_evaluator.c` constructors
2287–2360, evaluate_transaction 2190+, select_cost_model 1570+. Config is a total
record of validated SlotConfig, Word64 protocolMajor and validated CostModels;
`evaluator :: Config -> Evaluator` preserves the existing per-request Target.
A new evaluator is constructed per call so operations share no mutable handle.
Missing cost model lookup (including an empty map, not only NULL) selects native
version defaults. Native uses fixed shared CPU100000000000/mem100000000 ceilings;
these are not configurable protocol transaction limits. Every requested target
reevaluates all levels, fails for failures elsewhere, and returns only selected
level budgets. V1–V3 cannot execute at sublevels. Models and programs remain
subject to native protocol/language checks.

Haskell preflight checks ordinary Evaluation target+duplicate resolution rules,
then every top/sub spending+reference input resolves and every explicit validity
endpoint passes checked slotToTime (including reference-slot underflow and
Word64 time overflow). Additional unrelated UTxOs are allowed. Collateral is
not executed/resolved by ScriptContext input construction and is not required.
Inputs/outputs and returned redeemers traverse public typed values; output
budgets are checked against exact original redeemer arguments and identifiers.
Original input transaction and every encoding remain untouched.

Native boundary ownership: operation owns transaction, UTxO list, cost model map,
evaluator, redeemer list, readers/writer. Constructors copy schedule, retain
cost map, adopt context internally; C adapter separately releases evaluator and
its original map reference. List insert retains; child ownership released each
iteration. Partial parsed output is released on every failure. Output/diagnostic
slots initialize NULL before work. On native failure diagnostic is copied from
evaluator before unref; static status text is fallback. Haskell bracket owns both
buffers throughout safe FFI, status inspection and copy. Pending cancellation
unwinds only after synchronous safe C completion; no native worker escapes the
scope. Safe import leaves unrelated Haskell capabilities schedulable. No public
C internals, UPLC AST builders, handles or reference-count operations exposed.

Test fixture provenance: Apache-2.0 cardano-c pinned commit above,
`lib/tests/uplc/native_tx_evaluator.cpp`: build_succeeds_program_cbor (157+),
build_v3_script (109+), build_v4_script (2083+), uniform V4 cost test (3450+).
Flat programs reconstructed as minimal serialized compiled programs, then
imported as PlutusScript public values; policies derive via real script hashing,
Mint/Fields/Witnesses/Transaction assemble typed fixtures. No private AST FFI.
Test cases in NativeEvaluation exercise V1–V4 mint execution, exact indefinite
input CBOR/no implicit budget mutation, V4 exact defaults/custom coefficient
budgets, malformed/unavailable scripts with copied diagnostics, phase2 failures,
subtarget bounds/language/failure anywhere, fast cross-level budget exhaustion,
complete resolution/duplicates/slots, repeated success and partial transport
errors. Native allocation checks use Valgrind in addition to operation-repeat tests.

#### Deferred redeemer API and source review

Reviewed before design against native eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1:

* `lib/include/cardano/transaction_builder/balancing/deferred_redeemer_list.h`, `lib/src/transaction_builder/balancing/deferred_redeemer_list.c`: list add retains the redeemer but borrows callback/context; destruction releases retained redeemers only. Resolve invokes registrations in order each balancing iteration, transfers one fresh payload from callback, sets data on the witness-set's shared redeemer and unreferences payload on success/failure. Null list is no-op, empty list has no invocations; duplicate list entries are permitted by C. Successful callback with null output is failure. Haskell does not expose native registration plumbing or null payloads.
* `transaction_builder.h`, `transaction_builder.c`, internals `builder_inputs.c`, `builder_mint.c`, `builder_withdrawals.c`, `builder_certs.c`, `builder_redeemers.c`: deferred convenience calls construct Constr 0 [] placeholder, register callback against existing purpose map object. Deferred input duplicate registration latches builder failure. Mint policy map duplicate insertion preserves original redeemer; therefore grouped multiasset mint registers a callback for its first normalized nonzero asset and uses ordinary mint with NULL redeemer for other assets. This avoids registering several callbacks for one policy. Ordered normalization determines the first asset reproducibly.
* Native tests `lib/tests/transaction_builder/balancing/deferred_redeemer_list.cpp` and `lib/tests/transaction_builder/transaction_builder.cpp` around lines12768-13690: actual self-index spend workflow; callback failure/null payload; mint, zero withdrawal and certificate registration; allocation failure. Upstream deferred builder success uses provider-backed evaluator fakes, independently of VM validation. Cometa tests reproduce caller workflows with owned typed values and injected evaluator, plus a real VM V4 mint. No upstream test source copied. License Apache-2.0.
* `examples/src/deferred_redeemer_self_index_example.c`, `deferred_redeemer_batch_example.c`, `deferred_redeemer_withdraw_zero_example.c`: caller captures resolved identity, obtains canonical draft indices and returns a data payload; zero withdrawal is a script authorization purpose. Native documentation requires deterministic callbacks and states subbuilder callback timing differs (one invocation with local sorted draft, not top-level balancing).

Haskell API review:

* Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9 [Types/Redeemer.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Redeemer.hs), source cached `/tmp/p11-atlas-redeemer.hs`; [TxBuilder/Class.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs) cached `/tmp/cometa-haskell-review/atlas-class.txt`: GYRedeemer is immediate BuiltinData, conversion to cardano-api HashableScriptData; mustMint takes a script, one redeemer, name and quantity, stores policy -> (asset quantities,redeemer), and zero amount is mempty. mustHaveInput/output assemble skeletons. No late redeemer callback appears in these reviewed APIs. Do not claim an established Atlas late workflow. Cometa follows typed immutable data and grouped policy semantics while adding native-supported deferred resolution explicitly, returning Either rather than implicit bottom/user exceptions for expected failures.
* cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5 [Tx/Internal/Body.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs), cached `/tmp/p11-cardano-api-body.hs`: indexTxIns sorts TxIn before zip; indexTxMintValue enumerates policy map, indexTxWithdrawals ordered addresses; script-purpose index comes from body collections rather than redeemer argument. [Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs), cached `/tmp/p09-api-fee.hs`, estimateBalancedTxBody substitutes execution units before balancing. This supports distinguishing purpose index from body-dependent argument; it does not establish a pure late-argument API identical to Cometa's. Reviewed source licenses Apache-2.0; none copied.

Approved workflow: validate input values once; construct a Plan using `type DeferredRedeemer = Transaction -> [Utxo] -> Either Error EncodedPlutusData`; `Builder.build config plan` is the one effect/error boundary; inspect/reuse resulting owned transaction. Spend/withdraw/certificate variants attach pure callbacks. `mintWithDeferredRedeemer :: PolicyId -> [(AssetName,Int64)] -> DeferredRedeemer -> Plan` groups one callback per policy, allows empty/netzero no-op groups. No raw pointer, FunPtr, StablePtr, manual cleanup or effectful callback appears publicly.

Plan keeps ordered composition but removes Eq/Show because functions have no lawful structural equality or printable representation. Internally arguments contain pure immediate data or callback-table indices (both lawful Eq/Show); composition appends closure tables and rebases right indices. Associativity follows concatenation plus additive rebase; identity preserves indices. Function comparison is never attempted. Duplicate deferred spending/reward/policy registrations (including p<>p with same closure) are explicit conflicts. Same-policy assets within one group share one table slot. Static idempotence and mint combination remain unchanged. Observational monoid tests compare encoded normalized operations, including deferred indices; successful repeated builds check retained closure ordering and output behavior. Follow-up: broader properties may compare successful builds under deterministic selection.

Lifetime/exception contract: a third grouped Runtime owns the dispatcher closure table. Native contexts are allocated in one fixed array before instruction registration, borrow active runtime, and remain valid until after native builder destruction. Builder destruction releases native deferred entries before context array free. All factories, callbacks, transaction serialization, native cleanup and context free occur inside one joined safe FFI operation. Cancellation signals every callback control and joins native worker before freeing any registration. Callback request copies draft and selected UTxOs to CBOR; Haskell decodes owned immutable values. Complete pure callback result evaluation, CBOR materialization, lazy error forcing and native reply copying execute in Runtime's protected callback worker. Typed callback errors survive native failure; exceptions propagate after unwind. Callback result is deterministic by public type/contract; Haskell cannot prevent unsafePerformIO abuse, so captured mutable state is explicitly outside contract. Plans/builds share no mutable registration state.

P12 pending contracts: subbuilder native invokes once with a transaction-shaped draft containing only the local sub body and local sorted resolved inputs, before parent balancing; top-level interpretation must never accidentally be used. Its borrowed context must live through subbuilder destruction and any retry, and owned snapshot decoding/error/cancellation rules must match top-level. Vote callback registration requires a separate public voting-plan workflow and is pending with governance builder integration. No public raw deferred list is needed: its lifecycle/registration/resolve operations are internal infrastructure; low-level list failure behavior remains native upstream evidence, with Haskell boundary tests covering impossible public nulls via type invariants.


### P11 transaction index helpers: API and ordering review

Reviewed cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`,
[Cardano.Api.Tx.Internal.Body](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs),
actual downloaded source `/tmp/p11-cardano-api-body.hs` (downloaded at the revision above). `indexTxIns` lines351–363 sorts by `TxIn` and zips zero-based
indices, including key witnesses; `indexTxMintValue` lines720–735 enumerates
ordered policies; `collectTxBodyScriptWitnesses` lines2296+ uses those indices
to associate scripts with transaction objects. Witness indices change when their
body collections change. Also reviewed the current rendered
[source](https://cardano-api.cardano.intersectmbo.org/cardano-api/src/Cardano.Api.Tx.Internal.Body.html)
on 2026-11-06.

Caller workflow: validate/import the input, address or policy once; assemble or
receive the complete `Transaction`; call qualified `Indices.findInput`,
`findReferenceInput`, `findOutput address minimumLovelace`, or `findMintPolicy`;
handle legitimate absence with `Maybe`; assemble the redeemer data inside an
existing deferred callback. These helpers inspect immutable values and introduce
no IO or additional error layer. Cometa uses its existing `Input` key rather than
the C hash/index argument pair, returns `Maybe Word64` matching native index
width, and avoids era/witness wrappers because these queries do not require them.
The four functions inspect the top level; nested transaction indices remain
independent.

Native audit at `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:

* `lib/src/transaction/transaction.c`786–985: input helpers scan the stored input
  set; output helper returns the first address match meeting minimum Ada; mint
  helper enumerates sorted policy keys.
* `transaction_body/transaction_input_set.c`208–236 and377–396 sorts parsed/added
  inputs using `cardano_transaction_input_compare`. The comparator
  (`transaction_input.c`363+) orders hash bytes then numeric index. Duplicate
  input references are retained, so later positions must not deduplicate them.
* `assets/multi_asset.c` inserts policy map entries without discarding empty maps,
  sorts them by hash and exposes those keys. Imported zero-only and empty policy
  maps affect native policy positions even though public semantic `Value`
  normalizes zero quantities. The pure helper reads only policy keys from exact
  validated body CBOR using existing private CBOR combinators, then sorts them.
  Public decoding already rejects duplicate policy keys in
  `Internal.TransactionValue.decodeAssets`; a regression asserts that boundary.
* `address/address.c`546+ compares address type and bytes; Cometa compares the
  exact validated address bytes. Output order is retained.

Intentional native correction: native output lookup casts the unsigned minimum
lovelace to signed `int64_t` (`transaction.c`918), causing thresholds above
`2^63-1` to match ordinary outputs after wrapping on the supported platform.
Cometa compares as `Integer`, retaining the documented unsigned threshold meaning.
Outputs are nonnegative and bounded by `2^63-1`, so larger thresholds correctly
return `Nothing`. Ordinary thresholds through `2^63-1` have native oracle tests;
the two larger boundaries have independent public tests. No native changes are included here.

Tests assemble typed transactions through public decoding/assembly, including a
noncanonical unsorted input list with duplicate references, numeric indices24/256,
output address/amount ties and absent matches, a burning policy plus empty and
zero-only policies, duplicate-policy rejection, empty collections, and threshold
boundaries. The independent C oracle invokes all four installed native index APIs
and releases reader/transaction/hash/address owners on every path. Fixtures are
newly authored here; no external vectors were copied. Native source is
Copyright Biglup Labs, Apache-2.0, at the pinned revision.


### P11: native evaluation and deferred redeemers

#### Native evaluator API and source review

Established Haskell source inspected before API design: cardano-api commit
`5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`,
[Tx/Internal/Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs),
local snapshot `/tmp/p09-api-fee.hs`: evaluateTransactionExecutionUnits 721–775;
auto-balance caller 1100–1155. Caller obtains system start/era history/protocol
parameters/resolved UTxO/body, executes scripts, inspects indexed per-script
failures and logs, substitutes budgets explicitly, and computes fees. Cometa
preserves explicit context, identifier-keyed results and separate mutation;
its synchronous native ABI reports all-or-error, so partial successes/logs are
not invented. Native slot config is a constant-duration schedule, not ledger
epoch history. Minor protocol version does not enter the native constructor.

Reviewed pinned native source/header at `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:
`lib/include/cardano/transaction_builder/evaluation/native_tx_evaluator.h`,
`lib/src/transaction_builder/evaluation/native_tx_evaluator.c` constructors
2287–2360, evaluate_transaction 2190+, select_cost_model 1570+. Config is a total
record of validated SlotConfig, Word64 protocolMajor and validated CostModels;
`evaluator :: Config -> Evaluator` preserves the existing per-request Target.
A new evaluator is constructed per call so operations share no mutable handle.
Missing cost model lookup (including an empty map, not only NULL) selects native
version defaults. Native uses fixed shared CPU100000000000/mem100000000 ceilings;
these are not configurable protocol transaction limits. Every requested target
reevaluates all levels, fails for failures elsewhere, and returns only selected
level budgets. V1–V3 cannot execute at sublevels. Models and programs remain
subject to native protocol/language checks.

Haskell preflight checks ordinary Evaluation target+duplicate resolution rules,
then every top/sub spending+reference input resolves and every explicit validity
endpoint passes checked slotToTime (including reference-slot underflow and
Word64 time overflow). Additional unrelated UTxOs are allowed. Collateral is
not executed/resolved by ScriptContext input construction and is not required.
Inputs/outputs and returned redeemers traverse public typed values; output
budgets are checked against exact original redeemer arguments and identifiers.
Original input transaction and every encoding remain untouched.

Native boundary ownership: operation owns transaction, UTxO list, cost model map,
evaluator, redeemer list, readers/writer. Constructors copy schedule, retain
cost map, adopt context internally; C adapter separately releases evaluator and
its original map reference. List insert retains; child ownership released each
iteration. Partial parsed output is released on every failure. Output/diagnostic
slots initialize NULL before work. On native failure diagnostic is copied from
evaluator before unref; static status text is fallback. Haskell bracket owns both
buffers throughout safe FFI, status inspection and copy. Pending cancellation
unwinds only after synchronous safe C completion; no native worker escapes the
scope. Safe import leaves unrelated Haskell capabilities schedulable. No public
C internals, UPLC AST builders, handles or reference-count operations exposed.

Test fixture provenance: Apache-2.0 cardano-c pinned commit above,
`lib/tests/uplc/native_tx_evaluator.cpp`: build_succeeds_program_cbor (157+),
build_v3_script (109+), build_v4_script (2083+), uniform V4 cost test (3450+).
Flat programs reconstructed as minimal serialized compiled programs, then
imported as PlutusScript public values; policies derive via real script hashing,
Mint/Fields/Witnesses/Transaction assemble typed fixtures. No private AST FFI.
Test cases in NativeEvaluation exercise V1–V4 mint execution, exact indefinite
input CBOR/no implicit budget mutation, V4 exact defaults/custom coefficient
budgets, malformed/unavailable scripts with copied diagnostics, phase2 failures,
subtarget bounds/language/failure anywhere, fast cross-level budget exhaustion,
complete resolution/duplicates/slots, repeated success and partial transport
errors. Native allocation checks use Valgrind in addition to operation-repeat tests.

#### Deferred redeemer API and source review

Reviewed before design against native eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1:

* `lib/include/cardano/transaction_builder/balancing/deferred_redeemer_list.h`, `lib/src/transaction_builder/balancing/deferred_redeemer_list.c`: list add retains the redeemer but borrows callback/context; destruction releases retained redeemers only. Resolve invokes registrations in order each balancing iteration, transfers one fresh payload from callback, sets data on the witness-set's shared redeemer and unreferences payload on success/failure. Null list is no-op, empty list has no invocations; duplicate list entries are permitted by C. Successful callback with null output is failure. Haskell does not expose native registration plumbing or null payloads.
* `transaction_builder.h`, `transaction_builder.c`, internals `builder_inputs.c`, `builder_mint.c`, `builder_withdrawals.c`, `builder_certs.c`, `builder_redeemers.c`: deferred convenience calls construct Constr 0 [] placeholder, register callback against existing purpose map object. Deferred input duplicate registration latches builder failure. Mint policy map duplicate insertion preserves original redeemer; therefore grouped multiasset mint registers a callback for its first normalized nonzero asset and uses ordinary mint with NULL redeemer for other assets. This avoids registering several callbacks for one policy. Ordered normalization determines the first asset reproducibly.
* Native tests `lib/tests/transaction_builder/balancing/deferred_redeemer_list.cpp` and `lib/tests/transaction_builder/transaction_builder.cpp` around lines12768-13690: actual self-index spend workflow; callback failure/null payload; mint, zero withdrawal and certificate registration; allocation failure. Upstream deferred builder success uses provider-backed evaluator fakes, independently of VM validation. Cometa tests reproduce caller workflows with owned typed values and injected evaluator, plus a real VM V4 mint. No upstream test source copied. License Apache-2.0.
* `examples/src/deferred_redeemer_self_index_example.c`, `deferred_redeemer_batch_example.c`, `deferred_redeemer_withdraw_zero_example.c`: caller captures resolved identity, obtains canonical draft indices and returns a data payload; zero withdrawal is a script authorization purpose. Native documentation requires deterministic callbacks and states subbuilder callback timing differs (one invocation with local sorted draft, not top-level balancing).

Haskell API review:

* Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9 [Types/Redeemer.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Redeemer.hs), source cached `/tmp/p11-atlas-redeemer.hs`; [TxBuilder/Class.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs) cached `/tmp/cometa-haskell-review/atlas-class.txt`: GYRedeemer is immediate BuiltinData, conversion to cardano-api HashableScriptData; mustMint takes a script, one redeemer, name and quantity, stores policy -> (asset quantities,redeemer), and zero amount is mempty. mustHaveInput/output assemble skeletons. No late redeemer callback appears in these reviewed APIs. Do not claim an established Atlas late workflow. Cometa follows typed immutable data and grouped policy semantics while adding native-supported deferred resolution explicitly, returning Either rather than implicit bottom/user exceptions for expected failures.
* cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5 [Tx/Internal/Body.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs), cached `/tmp/p11-cardano-api-body.hs`: indexTxIns sorts TxIn before zip; indexTxMintValue enumerates policy map, indexTxWithdrawals ordered addresses; script-purpose index comes from body collections rather than redeemer argument. [Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs), cached `/tmp/p09-api-fee.hs`, estimateBalancedTxBody substitutes execution units before balancing. This supports distinguishing purpose index from body-dependent argument; it does not establish a pure late-argument API identical to Cometa's. Reviewed source licenses Apache-2.0; none copied.

Approved workflow: validate input values once; construct a Plan using `type DeferredRedeemer = Transaction -> [Utxo] -> Either Error EncodedPlutusData`; `Builder.build config plan` is the one effect/error boundary; inspect/reuse resulting owned transaction. Spend/withdraw/certificate variants attach pure callbacks. `mintWithDeferredRedeemer :: PolicyId -> [(AssetName,Int64)] -> DeferredRedeemer -> Plan` groups one callback per policy, allows empty/netzero no-op groups. No raw pointer, FunPtr, StablePtr, manual cleanup or effectful callback appears publicly.

Plan keeps ordered composition but removes Eq/Show because functions have no lawful structural equality or printable representation. Internally arguments contain pure immediate data or callback-table indices (both lawful Eq/Show); composition appends closure tables and rebases right indices. Associativity follows concatenation plus additive rebase; identity preserves indices. Function comparison is never attempted. Duplicate deferred spending/reward/policy registrations (including p<>p with same closure) are explicit conflicts. Same-policy assets within one group share one table slot. Static idempotence and mint combination remain unchanged. Observational monoid tests compare encoded normalized operations, including deferred indices; successful repeated builds check retained closure ordering and output behavior. Follow-up: broader properties may compare successful builds under deterministic selection.

Lifetime/exception contract: a third grouped Runtime owns the dispatcher closure table. Native contexts are allocated in one fixed array before instruction registration, borrow active runtime, and remain valid until after native builder destruction. Builder destruction releases native deferred entries before context array free. All factories, callbacks, transaction serialization, native cleanup and context free occur inside one joined safe FFI operation. Cancellation signals every callback control and joins native worker before freeing any registration. Callback request copies draft and selected UTxOs to CBOR; Haskell decodes owned immutable values. Complete pure callback result evaluation, CBOR materialization, lazy error forcing and native reply copying execute in Runtime's protected callback worker. Typed callback errors survive native failure; exceptions propagate after unwind. Callback result is deterministic by public type/contract; Haskell cannot prevent unsafePerformIO abuse, so captured mutable state is explicitly outside contract. Plans/builds share no mutable registration state.

P12 pending contracts: subbuilder native invokes once with a transaction-shaped draft containing only the local sub body and local sorted resolved inputs, before parent balancing; top-level interpretation must never accidentally be used. Its borrowed context must live through subbuilder destruction and any retry, and owned snapshot decoding/error/cancellation rules must match top-level. Vote callback registration requires a separate public voting-plan workflow and is pending with governance builder integration. No public raw deferred list is needed: its lifecycle/registration/resolve operations are internal infrastructure; low-level list failure behavior remains native upstream evidence, with Haskell boundary tests covering impossible public nulls via type invariants.


### P11 transaction index helpers: API and ordering review

Reviewed cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`,
[Cardano.Api.Tx.Internal.Body](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs),
actual downloaded source `/tmp/p11-cardano-api-body.hs` (downloaded at the revision above). `indexTxIns` lines351–363 sorts by `TxIn` and zips zero-based
indices, including key witnesses; `indexTxMintValue` lines720–735 enumerates
ordered policies; `collectTxBodyScriptWitnesses` lines2296+ uses those indices
to associate scripts with transaction objects. Witness indices change when their
body collections change. Also reviewed the current rendered
[source](https://cardano-api.cardano.intersectmbo.org/cardano-api/src/Cardano.Api.Tx.Internal.Body.html)
on 2026-11-06.

Caller workflow: validate/import the input, address or policy once; assemble or
receive the complete `Transaction`; call qualified `Indices.findInput`,
`findReferenceInput`, `findOutput address minimumLovelace`, or `findMintPolicy`;
handle legitimate absence with `Maybe`; assemble the redeemer data inside an
existing deferred callback. These helpers inspect immutable values and introduce
no IO or additional error layer. Cometa uses its existing `Input` key rather than
the C hash/index argument pair, returns `Maybe Word64` matching native index
width, and avoids era/witness wrappers because these queries do not require them.
The four functions inspect the top level; nested transaction indices remain
independent.

Native audit at `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:

* `lib/src/transaction/transaction.c`786–985: input helpers scan the stored input
  set; output helper returns the first address match meeting minimum Ada; mint
  helper enumerates sorted policy keys.
* `transaction_body/transaction_input_set.c`208–236 and377–396 sorts parsed/added
  inputs using `cardano_transaction_input_compare`. The comparator
  (`transaction_input.c`363+) orders hash bytes then numeric index. Duplicate
  input references are retained, so later positions must not deduplicate them.
* `assets/multi_asset.c` inserts policy map entries without discarding empty maps,
  sorts them by hash and exposes those keys. Imported zero-only and empty policy
  maps affect native policy positions even though public semantic `Value`
  normalizes zero quantities. The pure helper reads only policy keys from exact
  validated body CBOR using existing private CBOR combinators, then sorts them.
  Public decoding already rejects duplicate policy keys in
  `Internal.TransactionValue.decodeAssets`; a regression asserts that boundary.
* `address/address.c`546+ compares address type and bytes; Cometa compares the
  exact validated address bytes. Output order is retained.

Intentional native correction: native output lookup casts the unsigned minimum
lovelace to signed `int64_t` (`transaction.c`918), causing thresholds above
`2^63-1` to match ordinary outputs after wrapping on the supported platform.
Cometa compares as `Integer`, retaining the documented unsigned threshold meaning.
Outputs are nonnegative and bounded by `2^63-1`, so larger thresholds correctly
return `Nothing`. Ordinary thresholds through `2^63-1` have native oracle tests;
the two larger boundaries have independent public tests. No native changes are included here.

Tests assemble typed transactions through public decoding/assembly, including a
noncanonical unsorted input list with duplicate references, numeric indices24/256,
output address/amount ties and absent matches, a burning policy plus empty and
zero-only policies, duplicate-policy rejection, empty collections, and threshold
boundaries. The independent C oracle invokes all four installed native index APIs
and releases reader/transaction/hash/address owners on every path. Fixtures are
newly authored here; no external vectors were copied. Native source is
Copyright Biglup Labs, Apache-2.0, at the pinned revision.


Canonical-order correction found by the strengthened two-input workflow: native `transaction_balancing.c` calls set_transaction_inputs(body,selection,...) to canonically order the body, then passes the original selection list to deferred_redeemer_list_resolve at line2995. Thus the actual list can remain selection/insertion order despite deferred_redeemer_list.h claiming canonical resolved order. The Haskell dispatcher sorts owned UTxOs by Utxo.input, verifies their reference multiset exactly equals the draft body spending inputs, and only then calls user code. A native mismatch becomes NativeContractViolation builder.deferredInputs. The nontrivial test registers script input first, a key input with lexically smaller txid second; callback receives canonical snapshots and final script index1. This is required adapter normalization, not reliance on header prose.


#### Integrated checks and remaining scope

The integrated suite passes 404 tests (307 public-package tests and 97 runtime
and builder tests). All 29 offline executables run, including native V4 evaluation
and a balanced deferred mint. Public Haddock declarations have complete coverage;
strict guide HTML/link checks, formatters, HLint, package metadata, native inventory
and key/credential compile-fail checks pass. The full runtime suite passes
Valgrind with zero errors and zero definitely, indirectly or possibly lost bytes;
no suppressions were used. Source-package and public-suite Valgrind results are
recorded on the PR alongside hosted compiler/platform checks.

This batch covers the installed native evaluator constructors, top-level deferred
spending/minting/withdrawal/certificate operations and four transaction-index
queries. UPLC parser, AST and CEK declarations are private native headers, not
missing installed APIs. Voting callbacks, subtransaction building and deferred
local drafts remain P12 work. Remaining contextual authority/index queries and
JSON inspection retain explicit pending ledger entries; this is not a claim
of complete Dijkstra building or live-network conformance.


### Deferred ergonomics review

A future API ergonomics pass may introduce explicit `ToPlutusData` conversion
for domain redeemers, keeping `Either Error` in deferred callbacks and preserving
exact bytes for existing encoded values. This is intentionally deferred: current
building work retains `EncodedPlutusData` and does not add generic derivation or
implicit constructor-tag choices. Review schema compatibility and complete caller
workflows before adopting the class.


### P12: Dijkstra building and contextual accounting

#### Balance workflow and source review

Reviewed the existing pinned cardano-api Fee.hs evaluation/balance workflow and
[sc-tools CoinSelection.balanceChanges](https://github.com/input-output-hk/sc-tools/blob/main/src/coin-selection/lib/Convex/CoinSelection.hs)
(current main source reviewed 2026-11-06). sc-tools computes address-level input/output
changes from resolved UTxOs; Cometa instead exposes the native ledger conservation
quantity, including deposits, refunds, withdrawals, minting, donation and direct
account deposits. Positive values are surplus and negative values are deficit.

At native revision `eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`, reviewed
`transaction_builder/balancing/transaction_balancing.{h,c}` and its
`compute_imbalance`, `compute_*_imbalance`, `add_repeated_pool_deposits`, and
`is_transaction_balanced` paths. Top-level accounting deliberately excludes
subtransactions; batch accounting includes all bodies and refunds pool deposits
charged in more than one body. Local intents have no fee. The caller resolves
spending inputs; reference and collateral inputs do not contribute value.

The public Building functions reuse the existing `Parameters`, `Utxo`,
`Transaction`, `SubTransaction`, signed `Value` and `IO (Either Error ...)`
boundary. No special balance wrapper or effect framework is needed. Missing or
duplicate resolution is rejected. Preflight computes all native body arithmetic
intermediates in Integer, then checks signed bounds before native additions.
For batches, separately bounded positive/negative component totals protect any
native body iteration order, including the repeated-pool refund. Native results
use a private signed coin/assets tuple because ledger Value CBOR encodes unsigned
coin. Parsed values, references, parameters and result buffers are scoped on
success and failure. `isBalanced` is exactly zero batch imbalance; it does not
assert chain availability, valid signatures, scripts or ledger admission.


### P12 contextual transaction utilities

Reviewed actual established Haskell source before implementation:

* cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5,
  [Tx.Internal.Body](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs),
  downloaded /tmp/p11-cardano-api-body.hs: indexTxWithdrawals548+ orders stake
  addresses; indexTxCertificates645+ includes witnessed and unwitnessed certs in
  list order; indexTxVotingProcedures781+ obtains voter rank from the ledger
  map, independent of action count. collectTxBodyScriptWitnesses2296+ uses these
  identities to associate body objects with script witnesses. Cometa follows the
  complete-body, zero-based ordering workflow without era/witness wrappers.
* Same commit,
  [Tx.Internal.Fee](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs),
  actual /tmp/p09-api-fee.hs: estimateTransactionKeyWitnessCount496+ unions a
  role-neutral Set(KeyHash Witness) for extra keys, withdrawals, certificates
  including pool owners, and voters, then conservatively counts inputs and
  collateral because resolved UTxO keys are unavailable. Auto-balance1158+
  explains this overestimate and uses resolved UTxO data for fee calculation.
  Cometa receives resolved snapshots and exposes the native unique direct hashes
  as Set Blake2bHash, checks every returned digest has28bytes, and assigns no
  payment/stake/governance role to a heterogeneous authority set.

Workflow: validate/import address, voter, existing RedeemerId or encoded
certificate; inspect a complete immutable transaction with qualified Indices
helpers; handle legitimate absence with Maybe; assemble deferred redeemer data.
Certificate canonicalization uses one IO(Either Error ...) boundary. Indices
become stale after body edits. SubTransaction.Indices inspects one local level.
For signing, pass complete outer spending/collateral resolutions to
Transaction.Authority.requiredKeyHashes, handle one error boundary, then select
wallet signing keys by the resulting unique role-neutral hashes.

Exact native audit: eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1.

* Public transaction/transaction.h declares8 find functions and get_unique_signers.
  sub_transaction.h has no index or authority discovery equivalents. Sub index
  APIs are shared level-local Haskell inspection conveniences.
* transaction.c993+ withdrawal lookup delegates to common/ledger_order.c. Rank
  key: network class(testnet0/mainnet1), credential(script0/key1), hash bytes.
  All non1 network tags map to testnet class0. Native counts every strictly
  smaller key and detects equality by this normalized key, including network
  aliases. Public RewardAddress ordinarily orders exact network then KEY before
  SCRIPT, so its Ord is unsuitable for ledger rank.
* transaction.c1140+ voter lookup: committee, DRep, pool; SCRIPT before KEY within
  role; then hash bytes. One voter counts once despite multiple action votes.
  Public Voter Ord places KEY before SCRIPT and must not determine ledger rank.
* transaction.c1170+ redeemer lookup counts smaller(tag,index) identities,
  independent of witness collection order. Public schema rejects duplicate
  identities and indices aboveWord32.
* transaction.c1056+ certificate lookup serializes native subtypes and compares
  their bytes, retaining list order/duplicates. Subtype codecs canonicalize
  containers and integer widths. Semantic Certificate Eq is insufficient:
  UnitInterval retains numerator/denominator for encoding but Eq compares numeric
  values; native bytes distinguish2/4 from1/2. findCertificate therefore accepts
  EncodedCertificate and runs native canonical comparison in IO. Public pool
  owner decoder rejects duplicates, so that native corner cannot enter a Cometa
  validated transaction.
* unique_signers.c1259+ analyzes ONLY outer key guards, spending/collateral
  payment addresses, key withdrawals, supported certificates and key voters.
  get_required_signers filters script guards. No native-script required-key
  discovery, script credential keys, Byron bootstrap authorities, nested levels,
  or legacy update delegate-state discovery is promised. This is direct native
  authority analysis, not complete script/ledger witness satisfaction.
* Complete outer spending/collateral resolution is required; duplicate
  references rejected. Extra UTxOs allowed; reference inputs are irrelevant.
  Native parsed snapshots are operation-local, and caller bytes never mutate.

Ownership: certificate adapter borrows collection/target, parses temporary
owners, assembles an empty native transaction containing those certs, calls the
public find function, then releases all readers/cert/set/input/output/body/witness/
transaction owners. ElementNotFound9 maps to Right Nothing; other statuses stay
NativeError. No private native AST. Authority adapter owns parsed tx/UTxOs/hash
set/writer/readers; initializes outputNULL, transfers only fresh serialized
buffer, and cleans partial state on failure. Runtime.withOwnedBuffer copies and
brackets that buffer. Safe synchronous FFI preserves schedulability; operations
have independent state, no callbacks, no interruptible native unwind.

Newly authored tests: test/ContextualTransaction.hs and independent public native
oracle test/cbits/contextual_transaction_oracle.c. Cover network aliases, mixed
key/script ledger ordering, multi-action voter deduplication, redeemer ranks,
nonminimal/indefinite certificate canonicalization, duplicate cert list positions,
rational2/4 vs1/2 semantic equality/native distinction, top/sub correspondence,
sub primitives/absence, exact input bytes, six distinct direct outer authorities,
native-script/script-guard/nested exclusions, unresolved reference allowed,
repeated success, missing/duplicate resolution, partial malformed tx/UTxO parses.
No external fixture copying. Native source copyright Biglup Labs, Apache-2.0.

Subtransaction authority discovery deliberately deferred: no public native
entrypoint, and requiredTopLevelGuards/level-signing semantics need separate audit.
Existing signed subtransaction witnesses are already serialized inside top body;
outer fee witness sizing must not add their sizes a second time or treat nested
keys as missing outer authorities.


### P12 sub-transaction builder API/source review

Before choosing this API, inspected actual established Haskell caller assembly
and evaluation workflow in cardano-api `5e63165a4bb7481a03d2e50464dc9c4f106c9fa5`
[Tx/Internal/Fee.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Fee.hs),
local `/tmp/p09-api-fee.hs`: createTransactionBody / explicit TxBodyContent before
evaluateTransactionExecutionUnits at1100–1155, indexed per-script execution and
protocol/resolved UTxO inputs at721–775, explicit budget substitution then fee
calculation. Inspected Atlas source snapshot `/tmp/protocol-atlas-balance.hs`
(commit c3adfb416242ea25a244bfaa1614213eecdc55d9, Apache-2.0),
GeniusYield.Transaction.CoinSelection.Balance SelectionParams/SelectionResult,
separating requested outputs from selected inputs/change and balance failures.
Neither source establishes a native Dijkstra local-intent contract: that is
reviewed directly against the pinned native API and not inferred from Haskell
fee/balancing names. Cometa retains owned typed values, ordinary monoidal plans,
explicit protocol/input snapshots and one IO(Either Error a) build boundary;
uses a distinct SubTransaction.Plan and Builder because local intents must not
silently select inputs, add change, fee or collateral.

Native audited at eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1:
`lib/include/cardano/transaction_builder/sub_transaction_builder.h`,
`lib/src/transaction_builder/sub_transaction_builder.c`,
`internals/builder_sub_build.{c,h}`, `builder_state.c`, `builder_outputs.c`,
`builder_mint.c`, `balancing/deferred_redeemer_list.c`. Build creates the exact
supplied input set/outputs, assigns spend indices, resolves deferred callbacks
once against state.transaction (body inputs installed, fee0), then checks
redeemers, copies all allowed fields into a sub body and evaluates native V4.
Evaluation creates an empty carrier batch containing this sub at index0; returned
budgets therefore need not match execution in the eventual outer context.
Finally script-data hash is computed from evaluated redeemers. No balancing,
fee/minAda computation or implicit coin summation occurs in this local path.
`builder_add_output` only retains an output in its list. Native fixed global
VM budget remains100m memory/100b CPU. No evaluator/selector injection is exposed
because those do not exist in the public native sub-builder.

Config is total record Parameters/SlotConfig/Fields.BodyNetwork, avoiding the
broader address NetworkId0..15 domain for ledger body network0/1. Abstract local
Plan wraps shared internal Plan to reuse intrinsic conflict checks, normalization,
callback indexing and canonical transport while exposing only sub-valid ops.
Nested sub-attachment and starting-account-balance operations are not exposed.
Local-only requireTopLevelGuard uses shared private tag26 but no public top-plan
constructor. Public resolvedInputs supports retaining snapshots for later outer
attachment; build validates every original conflicting snapshot before this
accessor's unique sorted result is used in the successful workflow.

Preflight validates shared intrinsic plan checks, all supplied validity endpoints,
native parameter representation, aggregate input/source and output/sink quantities
and key/pool/governance/DRep deposits within signed64. Native local build itself
has no monetary balance arithmetic; these conservative bounds also avoid carrying
unrepresentable aggregates into the enclosing native builder. Postbuild checks
actual sub CBOR <=protocol maxTxSize, each output's fresh serialized value size
<=optional maxValueSize and total evaluated exunits <=required maxTxExUnits when
redeemers exist. No balance, minimumAda or complete ledger admission assertion.
Later witnesses/outer fields consume additional size. Local callback dispatch
canonicalizes owned UTxO snapshots and checks exact reference correspondence and
zero draft fee before user invocation. Reference inputs are absent from callback
spending snapshots, but present in local draft and explicit resolver list.

Ownership: C parses fresh parameters, reader(s), instruction objects, builder,
resultsub, writer, buffers. Native state retains params and every inserted child;
local parsed references are unref'd after each operation. Shared typed proposal
conversion retains action/account/anchor children, all released after native
builder has built/retained its independently owned proposal. Context-array
storage is allocated for complete instruction count before registration and
freed only after sub-builder destruction. Native callback registrations borrow
user_context; Runtime State roots complete plan/closures until safe native C
return and callback worker joins. One runtime gate encloses all native acquisition,
callbacks and destruction. Success output and copied failure diagnostic transfer
two independent bracketed buffers; no native pointer escapes the operation.
Partial callback replies (including parsed payload followed by trailing bytes)
release partial payload before native list cleanup. Expected Error identity,
lazy payload exceptions and cancellation use shared Runtime exception protocol.

Public native symbol adaptation: typed certificate operation replaces all
staking/DRep certificate shorthand constructors; typed payTo replaces send/lock
shorthands without hiding native domain behavior; typed policy/name mint replaces
hex/id aliases. Typed Action proposal dispatch reaches all seven native proposal
constructors, supplying configured deposit. Single/shared-voter immediate/deferred
vote operations, guards, required outer guards, direct deposits, balance intervals,
network, donation and slot validity all have direct native effects. No raw handle,
refcount or error-buffer setter appears publicly.

Tests SubTransactionBuilder: exact unbalanced intent inputs/outputs; nativeV4
immediate/deferred agreement, exact budgets + commitment; reference script only
resolution; canonical out-of-order2-input local deferred index and one callback;
guards/account deposits/intervals/donation/required outer guard; all seven proposal
constructors+protocol deposit; grouped two-action voting one callback; conflict,
old-language and slot errors; signed aggregate/deposit, serialization/value size,
execution cap errors; original typed error, lazy payload poison, malformed plan,
partial trailing reply repeated cleanup+GC, cancellation after observed callback
entry and registration baseline. V4 Flat lambda-unit fixture derived from native
Apache-2.0 lib/tests/uplc/native_tx_evaluator.cpp build_v4_script at pinned commit.
Existing native/public
codec tests remain authoritative for imported certificate/governance corpus.

Compiled example SubTransactionBuilding builds an exact local intent, signs its
own hash with existing Signing.signSubTransaction, attaches signed bytes and
resolved snapshots, balances parent funds and batch, signs parent, calls
Building.isBalanced on the complete resolved union and prints both body hashes.
All references/keys/funds are synthetic; no network calls.


## P12 top-level governance/Dijkstra/batch builder research

Reviewed native eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1 headers/source before API implementation: transaction_builder/transaction_builder.h and corresponding .c; internals builder_entities.c, builder_proposals.c, builder_votes.c, builder_redeemers.c, builder_build.c; balancing/transaction_balancing.c; proposal_procedures/proposal_procedure.h and retained getter definitions; account_balance_interval.c; fee.h. Public APIs remain pure Plan assembly and one IO(Either Error Transaction) build boundary. No ToPlutusData ergonomics added; user deferred that topic.

Haskell caller design evidence reviewed actual sources:

* sc-tools 4546122230491db4839a4a42fc2bc601f7900909 [Convex.BuildTx](https://github.com/input-output-hk/sc-tools/blob/4546122230491db4839a4a42fc2bc601f7900909/src/base/lib/Convex/BuildTx.hs), cached /tmp/cometa-haskell-review/sc-build.txt. addWithdrawal modifies a body builder; addScriptWithdrawalWithRedeemerFn accepts a pure TxBodyContent -> redeemer function, packages it as a witness and adds a withdrawal. The caller obtains network, constructs typed stake authority, declares witness function, and interprets body construction later. lookupIndex* total Maybe helpers coexist with partial findIndex* convenience functions. Cometa follows deferred pure snapshots and total explicit errors, not ToData typeclasses or partial lookup; runtime effects and ownership remain internal.
* Atlas c3adfb416242ea25a244bfaa1614213eecdc55d9 [TxBuilder/Class.hs](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/TxBuilder/Class.hs), cached atlas-class.txt: mustHaveVotingProcedures installs voter -> witness plus action/procedure Map; mustHaveProposalProcedures installs ordered proposal/witness pairs; mustHaveDonation stores donation; finaliseCert/proposal completion obtains deposit requirements from queried protocol context. Cometa uses one voter group/one redeemer for multiple actions, preserves proposal order and gets proposal deposits from the explicit Config protocol snapshot. It rejects conflicting requirements instead of a map's implicit precedence. Conway-era source does not establish Dijkstra batching/accounts support.
* cardano-api 5e63165a4bb7481a03d2e50464dc9c4f106c9fa5 [Tx/Internal/Body.hs](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Tx/Internal/Body.hs), cached /tmp/p11-cardano-api-body.hs: mkTxVotingProcedures accepts grouped procedures plus script witnesses and derives canonical voting witness indices; proposal body APIs index ordered proposal collections; treasury donation is a separate field from current treasury value. Cometa reuses existing typed governance values, groups callback ownership per voter, and exposes only native-supported builder fields. Native header has set_donation but no current-treasury setter; standalone Body.fieldTreasuryValue remains available for manual assembly, without claiming native builder coverage.

Native domain contracts:

Guards use Credential Guard; key guard equals signer, script guard requires supplied script. Top guardWithRedeemer takes ScriptHash, preventing key+argument misuse. Top-level guard scripts use V4; guard order includes existing required signers. Duplicate identical guard requirements are idempotent; conflicting arguments fail. Direct deposits must be positive and <=INT64_MAX individually and accumulated per account (native builder_entities.c285+ confirms both; zero is not invented rejection). Account and starting intervals are distinct; native permits lower>=upper (representability is not satisfiability), rejects no bounds. Haskell keeps identical interval idempotence and reports different requirements rather than native last-write wins. Donation instructions add with Integer accumulation and signed bound validation, then emit one setter preserving explicit0.

Proposal convenience functions create seven native action alternatives and supply protocol governanceActionDeposit. Haskell propose reward Action Anchor avoids accepting a Proposal.deposit that native would discard. Native ParameterChange and TreasuryWithdrawals require nonnull policy hash even though standalone Action supports absent guardrail; public docs state this native workflow restriction. Proposal encoding transports a typed proposal with placeholder deposit0, then retained native to_action/getter snapshots route to the seven native builder wrappers, releasing all temporary owners after builder retains its fresh proposal. Native proposal collection add appends without deduplication, preserving order and duplicate proposal instructions. All7 alternatives tested through public Haskell values against resulting semantic proposals/current deposit.

Grouped votes attach one immediate or deferred argument per voter with many action/procedure pairs. Empty deferred group roots its pure closure but never invokes it. Same-voter competing deferred groups have distinct rebased callback slots and fail consistency validation, without comparing functions. C registers one deferred callback for the first normalized vote in a group; later actions use ordinary vote NULL, preserving the original native hash->redeemer map object. Shared Runtime table/rooting/cancellation contracts from P11 remain unchanged; new vote callbacks use same protected snapshot/decode/force/copy worker.

Batch attach preserves exact sub CBOR, body hash and signatures by native retain; no edits/canonicalization of supplied sub occurs. Haskell requires every spend/reference snapshot, validates consistent snapshots and spending disjointness across all levels before C. Root/sub agent provide independent signed workflow. Parent wallet and collateral eligibility excludes every sub spend/reference, including overlap in wallet lists; explicit parent references still price independently. sourceExtras includes resolved sub spending value, positive mint, withdrawals and certificate refunds; sinkExtras includes sub outputs, burn, certificate deposits, exact declared sub proposal deposits, donation/direct deposits. Top proposal costs use configured deposit. Pure sums use Integer before native signed-bound conversion; typed Mint amounts already enforce Int64 before internal conversion. Outer witness reserve is outer-only; embedded sub witness bytes already occur in transaction size and are not counted as missing outer witnesses. validateBuilt caps aggregate outer+sub declared execution units and full serialized batch size.

Reference-script fee preflight forms outer possible selections/references plus each sub's spent/reference UTxOs once per level. The public standalone helper rejects duplicate identities; private native transport op1 deliberately accepts repeated snapshots across levels and prices total serialized script bytes through native tier logic once, avoiding underpricing by summing separate tier resets. Parameters are validated and required byte price checked before this private call. The native header explicitly bills repeated references per level, including native reference scripts and scripts not executed. Missing sub references are rejected by Cometa instead of native optional skip because complete fee/accounting snapshots are the public contract.

Source ownership: all new read_* objects are fresh local owners; native builder retains arguments; cleanup releases credential/interval/proposal/voter/action/procedure/sub/resolved-list on every path. Proposal to_action/getters all return retained refs, released locally after wrapper call. Attached sub bytes get parsed into native owned objects, retained through builder destruction, original encodings preserved by existing native cached original children. Deferred context array fixed allocation precedes registrations, freed only after builder destruction; grouped Runtime remains live through safe FFI unwind and final native cleanup.

Internal shared op26 RequiredTopLevelGuard is only exposed through SubTransaction.Plan; top validateTopLevel rejects it. New op schemas communicated to sub agent, and its adapter rejects top-only starting balances and attached subs. Reuse of Plan bytecode retains callback rebasing and existing law tests, with native adapters selecting level-specific calls.

No upstream code copied. Source licenses native/cardano-api/Atlas Apache-2.0, sc-tools licensing follows reviewed repository.

Native proposal runtime finding: ParameterChange/TreasuryWithdrawals wrappers always install a Proposing redeemer with fixed native unit payload d87980, not just a policy reference. Therefore their policy must resolve to an executable Plutus script. Native allOf[] policy fixtures fail (top requires collateral; sub evaluator cannot resolve script redeemer), corrected to actual V4 Flat lambda unit, full369parameter coefficients100 and collateral for top. Shared requiresEvaluation marks these proposals, preserving complete fee/budget preflight. Tests now run actual guardrails native VM. Public documentation states unit argument and native absence of a custom proposing argument API. Native also preserves duplicate proposals by direct array_push; no implicit set deduplication assumed.

Attached imported intent audits: validitySlots now includes each sub's invalidBefore/invalidAfter, preventing uint64 schedule multiplication overflow before C. Attached sub output values are checked against protocol maxValueSize before attachment, because native add_sub only checks IDs/resolution and immutable imported values bypass the local subbuilder. Regression cases cover maxBound validity endpoint and too-large encoded coin value with exact structured errors. Account empty bound pair remains native invalid, lower>=upper is not newly rejected.

Signed declared budget audit: parent native evaluator returns outer budgets only; stored signed sub budgets could be stale despite successful script execution. Internal.BatchValidation evaluates every nonempty sub target against finalTx and complete dedup resolved union, verifies actual memory/CPU <= stored declared budgets, and never modifies intent bytes. Top Builder now invokes this after ordinary decode/result limits; configured evaluator must support SubTransaction target, default uses Native.Config with original schedule/protocol/models. Native evaluator recomputes the complete batch for each target; repeated native work is a correctness cost, not hidden mutations. Actual imported V4 guard unit0 budget regression fails while adequate declared budget retains exact supplied sub CBOR; signed mint fixture supplied separately by subagent.

Native selector surplus evidence: coin_selection/internals/random_improve_coin_selector.c150/176 deliberately requires a nonempty outer selection and falls back to a single Ada pick even when no value is required. Empty-wallet surplus batch is expected InsufficientBalance; retained as regression. Success case supplies an independent fee-payer wallet input and verifies exact conservation: outer10m plus party surplus5m equals outer outputs14.8m plus fee0.2m; deficit test outer10m+party10m equals suboutputs12m+outeroutputs7.8m+fee0.2m. This matches native tests7951/8008, both of which supply batcher UTxOs. Public guide states default selector needs outer input.


#### Integrated validation and next phase

All 432 tests pass (307 public-package tests and 125 runtime tests). All 31
offline executables run, including local signing, signed batch assembly and
complete-batch conservation. The complete runtime suite passes Valgrind with
zero errors, zero definitely/indirectly/possibly lost bytes and no suppressed
allocations. Public declarations have complete Haddock coverage; strict guide
HTML/link checks, HLint, Ormolu, ClangFormat, package/inventory and key/credential
role checks pass. Source-package consumer and full public-suite Valgrind results
are recorded on the PR alongside hosted compiler/platform results.

Signed scripted intents are reevaluated in their final enclosing context before
the outer builder returns. Both budget components must fit the unchanged declared
limits. The native evaluator currently recomputes the whole batch for each target;
a future bulk-result API could avoid that repeated work without weakening the
check. Injected evaluators must implement subtransaction targets for such batches.

Next is the Blockfrost provider and applicable native example workflows (P13),
followed by the remaining symbol/inspection audit and release hardening. This
batch does not establish live-network Dijkstra acceptance. The ToPlutusData
ergonomics proposal remains deferred to a separate API review.


### P13: Blockfrost provider and connected workflows

The backend lives in the public `cometa:blockfrost` Cabal sublibrary, with HTTP/TLS
dependencies isolated from the main library. It produces the existing `Provider`
record; applications keep their builder, selector, evaluator and signer interfaces.
`withProvider` validates configuration once and scopes requests. Project credentials
have no printable instance. Errors carry operation names, HTTP status codes or
sanitized transport categories, never raw requests, credentials or response bodies.

Protocol mapping reviewed against Blockfrost OpenAPI commit
`1d4d5d8bac8f0c641eea5c6f7b1f3fbbed8d1505`,
[`src/schemas/epochs/epoch_param_content.yaml`](https://github.com/blockfrost/openapi/blob/1d4d5d8bac8f0c641eea5c6f7b1f3fbbed8d1505/src/schemas/epochs/epoch_param_content.yaml),
and the pinned native example's `blockfrost_pparam_parser.c`. Execution prices use
exact `Scientific` fractions, not binary floating point. Pool pledge influence and
reference-script prices are nonnegative fractions and may exceed one. Related
fields (prices, execution budgets, voting thresholds) must be complete as a group.
Unsigned quantities and signed cost-model coefficients are checked before narrowing.
The UTxO charge is a byte price only from Babbage; Alonzo's word charge is not
silently relabelled. Absent fields remain unavailable. The published backend schema
does not define the newer Dijkstra, Leios or Peras parameters, so these are not
invented or populated with speculative defaults. This backend limitation does not
remove the binding's separately tested offline transaction capabilities.

Initial HTTP fixture validation covers headers/path encoding, status errors,
redirect refusal, no implicit submission retry, bounded whole-request duration,
response size limits, cancellation recovery, escaped handles and scope drainage.
Local tests require permission to create loopback sockets; ordinary CI uses no
credentials or public network requests for those fixtures.

#### HTTP workflow and lifetime review

Reviewed the actual `http-client-0.7.19` sources before choosing the transport:
[public API](https://github.com/snoyberg/http-client/blob/http-client-0.7.19/http-client/Network/HTTP/Client.hs),
[request/response scope](https://github.com/snoyberg/http-client/blob/http-client-0.7.19/http-client/Network/HTTP/Client/Core.hs),
and [manager implementation](https://github.com/snoyberg/http-client/blob/http-client-0.7.19/http-client/Network/HTTP/Client/Manager.hs).
Also reviewed installed `http-client-tls-0.3.6.4`, `http-types-0.12.6` and
`scientific-0.3.10` source archives. No implementation code was copied.

A normal caller supplies a network and optional validated project ID to `defaultConfig`,
then uses the existing provider operations within `withProvider`. Configuration
sets whole-request and confirmation-poll intervals, bounded to 1–60,000 ms.
The transport uses the library's bracketed `withResponse` workflow with an 8 MiB
response limit, standard TLS certificate verification, encoded path/query values,
no redirects, and no automatic retry (including the client's reused-connection
retry predicate). Only HTTP exceptions are translated; asynchronous cancellation
propagates after cleanup. The request deadline includes connection acquisition,
DNS, TLS, headers and body reads.

A guarded active-request count prevents new requests after scope closure and
joins active requests before scope exit. Pure empty-result operations also check
scope state. `http-client`'s deprecated `closeManager` is a no-op, so the transport
sets the idle connection count to zero: response cleanup closes sockets instead
of retaining idle connections until GC. This intentionally trades connection
reuse for deterministic connection cleanup. It is a performance review item for
P14, not a claim that the manager has a deterministic destructor.

Loopback HTTP tests cover exact wire paths, headers and POST bytes, status 429,
redirect refusal, single-attempt submission, overridden timeouts, response bounds,
cancellation recovery and closure/drainage. Pure response tests cover exact values
above 2^53, all native script alternatives, reference-script/inline-datum payloads,
all documented protocol groups, and precise evaluation budget coverage.
Scientific exponents are bounded before conversion: even a bounded conversion
can overflow internal Int exponent arithmetic at extreme input exponents.
Regression tests exercise both Int bounds. Standard Aeson object-key parsing is
used; the binding additionally rejects semantic duplicate asset units, UTxO
identities and redeemer identities. It does not claim lexical duplicate-key
rejection for JSON objects.

#### Provider API and endpoint review

Reviewed [Atlas's Blockfrost provider](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Providers/Blockfrost.hs)
at `c3adfb416242ea25a244bfaa1614213eecdc55d9` and the
[Blockfrost Haskell SDK](https://github.com/blockfrost/blockfrost-haskell/tree/a540dff307503409e8eb764a4dc661f8a927d4aa)
at `a540dff307503409e8eb764a4dc661f8a927d4aa`, including its Core, Types,
Cardano/Transactions and README sources. Their complete workflows informed typed
provider records, pagination, reference-script resolution and endpoint-specific
absence handling. Cometa keeps the existing `IO (Either Error a)` boundary,
explicit configuration and scoped capabilities; no mandatory SDK monad is added.
Unlike the reviewed Atlas conversion, protocol fractions remain exact and required
fields are checked without partial extraction. Unlike the SDK retry policy,
submission and rate-limited requests are not retried automatically.

The pinned OpenAPI requires nullable datum/reference-script fields in UTxO rows.
It defines a global asset UTxO endpoint; NFT lookup therefore need not infer unique
holdings from a list of asset addresses. Historical transaction outputs alone do
not prove spendability: resolve each requested output against current address
UTxOs, also respecting a supplied consumed-by transaction. Separate requests are
not an atomic snapshot. Datum and reference-script content hashes are checked
against requested identities. Plutus CBOR endpoint bytes are passed unchanged to
`Plutus.fromBytes`, matching the native example's `new_bytes_from_hex` behavior;
no speculative stripping of CBOR layers occurs. Timelock JSON reconstruction must
produce the requested hash or the query fails.

The [archived Ogmios 5.6 specification](https://ogmios.dev/api/v5.6/ogmios.wsp.json)
and Blockfrost's pinned evaluation request schema define `additionalUtxoSet` as
input/output pairs, with exact transaction CBOR, `policy[.name]` asset keys,
`datumHash`, inline datum CBOR, and native/V1/V2 reference scripts. The backend
explicitly requests version 5 and verifies exact redeemer budget coverage.
The native example mixes a newer additional-UTxO payload with the default legacy
dialect; that mismatch is not copied. Unsupported governance/Dijkstra features,
newer scripts and sub-transactions fail before remote evaluation. Local native
VM evaluation remains the normal builder path. A newer remote dialect is a
follow-up requiring an authoritative complete payload contract and integration
evidence; it is not advertised as implemented.

All provider fixtures are newly authored synthetic responses and deterministic
request schedules. No upstream implementation or test fixture was copied. Native
Blockfrost source is an example backend rather than installed C functionality,
so this phase adds no new public C symbols to the native coverage ledger.


### Native example source-to-Haskell inventory (pinned Apache-2.0 corpus)

Base source: [cardano-c examples/src](https://github.com/Biglup/cardano-c/tree/eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1/examples/src).
This maps executable domains/stages, not a claim that their live network scripts
were run or every literal/console message was copied.

| Native example | Haskell workflow | Evidence / deliberate differences |
| --- | --- | --- |
| `bip39_example.c` | WalletRecovery.hs; existing Bip39/SoftwareKeyHandler/Addresses examples | Mnemonic→entropy→encrypted handler→account+base address→signed synthetic payment; public demonstration material only. |
| `secure_key_handler_example.c` | WalletRecovery.hs + Blockfrost.Common/BlockfrostPayment.hs | Encrypted handler serialize/reload, account/payment derivation and scoped BIP32 signing; live entry accepts existing caller storage. |
| `provider_example.c` | BlockfrostQueries.hs; Workflows.Native.runStage | Protocol/address queries; reward queries are exercised by runRewardCycle. Dependent workflow stages requery fresh state. |
| `send_lovelace_example.c` | BlockfrostPayment.hs; Workflows.Native.runPayment | Query→balance→sign→explicit submit→confirm. NativeWorkflows payment fixture. |
| `mint_burn_native_script_example.c` | Workflows.Native.runMintBurn Native policy | Mint then confirm/requery/burn with real signer-backed native policy. Static CIP25 sample content not copied; typed Metadata domain already covered. |
| `mint_burn_plutus_script_example.c` | runMintBurn with resolved reference; NativeWorkflows.plutusMint | Fund reference output, resolve by exact ID, actual V3 mint→confirm/requery→burn. |
| `spend_from_native_script_example.c` | runLockSpend Native policy | Fund exact script output→confirm→spend with its native witness/signature. |
| `spend_from_validator_example.c` | runLockSpend actual native V3 | Fund inline datum+reference script→confirm→spend exact reference through reference input. |
| `reward_account_pubkey_example.c` | runRewardCycle key credential | Register/stake+vote delegate→query rewards→withdraw+deregister with explicit historic deposit. |
| `reward_account_script_example.c` | runRewardCycle actual native V2 | Native source-specific register+stake delegate only, then script withdrawal+deregistration. |
| `drep_pubkey_example.c` | runDRepCycle key credential | Register DRep, stake register/vote-delegate, stake withdraw/deregister, DRep deregister; explicit prepared registry state/deposits. |
| `drep_script_example.c` | runDRepCycle actual native V3 | Same complete lifecycle with script authorization and collateral. |
| `vote_for_proposal_pubkey_example.c` | runVoteCycle key DRep | Register→vote on explicit existing ActionId→deregister. |
| `vote_for_proposal_script_example.c` | runVoteCycle actual native V3 | Same lifecycle with actual script registration/voting/certificate execution. |
| `propose_treasury_withdrawal_example.c` | runTreasuryWithdrawal actual native V3 guardrails | Typed withdrawal map/anchor/policy, actual proposing script, sign+submit+confirm. |
| `donate_to_treasury_example.c` | runDonation | Typed donation included in fully balanced/signed/submitted fixture transaction. |
| `deferred_redeemer_self_index_example.c` | runDeferredSelf + actual Aiken selfIndex | Fund→confirm→deferred own canonical index→real enforcing script; wrong-index rejection test. |
| `deferred_redeemer_batch_example.c` | runDeferredBatch + actual Aiken orderPairing | Two confirmed orders, each late own-input/payout index, actual paired settlement; preserve reference output during second funding. |
| `deferred_redeemer_withdraw_zero_example.c` | runWithdrawZero + actual native V3 | Register/delegate, zero withdrawal forwards canonical input indices, cleanup certificate; actual enforcing script. |
| `sub_transaction_batch_example.c` | Workflows.Swap.runSwap + NativeSwap.hs | Exact native buyer/seller/batcher amounts and asset; independent signatures+required batcher guard+unchanged sub bytes+global conservation. |
| `plutus_v4_guarded_sub_transaction_example.c` | runGuardedSub actual native V4 programs | Fund validator, local V4 guarded intent, independent local signing, complete parent with collateral; actual sub budgets checked. |


The workflow fixture verifies each outer and nested Ed25519 witness against its own
body hash before changing UTxO state. A corrupted-signature regression requires
unchanged state and history. It also checks complete value conservation, but does
not implement consensus registration, rewards, eligibility or chain finality.


#### Integrated validation and remaining work

Local GHC 9.6.7 builds and all 493 tests pass: 325 public tests (including 18
complete workflow cases), 125 runtime tests and 43 Blockfrost tests. All three
suites pass Valgrind with zero errors, zero definitely/indirectly/possibly lost
bytes and zero matched suppressions in this run. The existing GHC scheduler
suppression remains configured. All 35 executable entry points run successfully:
33 offline examples and two connected command-line usage checks without action
arguments. No live network traffic or submissions are implied by those checks.

Both public API references have 100% declaration documentation coverage. The
portable archive generated by `tools/build-api-docs.py` contains core and
Blockfrost documentation with relative cross-component links; third-party links
use Hackage. Private backend modules are excluded from the public reference.
Formatting, HLint, native inventory, role checks and strict guide/link checks pass.
The core library's transitive build graph has no HTTP/TLS dependencies; those
belong solely to the optional component. A fresh source archive builds every
component with tests enabled and passes the same 493 tests.

Live preprod validation is recorded below. Staking, governance and Dijkstra
workflow cases above remain offline validation. P14 still covers the remaining native-symbol
mapping audit, performance review and final cross-platform/release hardening.
The deferred-redeemer ergonomics pass remains explicitly deferred. Newer remote
Blockfrost evaluation dialects are also not claimed by this implementation.


#### Custom endpoints and optional authentication

`Config.endpoint` accepts an absolute HTTP/HTTPS base URL, independently of the
selected network magic. `projectId` is `Maybe ProjectId`; `Nothing` omits the
header entirely. `defaultConfig network credential` still chooses the official
endpoint, while custom services can provide a different host, port, path and
query parameters. Operation query parameters override matching base keys. Paths,
including encoded bytes and repeated separators, retain their supplied meaning.

Reviewed `network-uri-2.6.4.2`'s `Network.URI.parseURI` and `http-client-0.7.19`'s
public `requestFromURI` and underlying request conversion. Parsing and conversion
use total `Maybe` results and return a sanitized configuration error before the
user action. Raw ports are bounded before the HTTP client's Int conversion;
otherwise a huge decimal could wrap into a valid-looking port. Tests include
IPv6, leading-zero ports, both port bounds and overflow inputs. Userinfo and URL
fragments are rejected; query parameters are supported and excluded from errors.
The reviewed Blockfrost Haskell SDK also supports custom URLs, but its partial
invalid-URL handling is not copied.

Four added loopback test groups exercise the public provider with custom paths,
query merging, present/absent authentication, independent network magic, and
invalid configuration before callback invocation. All 47 backend tests pass.
The connected examples accept optional `BLOCKFROST_URL` and
`BLOCKFROST_PROJECT_ID`; a missing project identifier no longer prevents startup.


#### Live Blockfrost preprod validation

The public provider was exercised against the official preprod service on
2026-11-07, using a custom endpoint URL with a trailing slash. The service reported
protocol version 11. Credentials and the encrypted public demonstration wallet
were supplied outside the repository.

Successful endpoint checks include protocol parameters, account rewards, address
UTxOs, asset-filtered address UTxOs, unique-asset UTxOs, transaction-input
resolution, datum CBOR, script metadata, native script JSON, Plutus script CBOR,
transaction submission and transaction confirmation. Known absent datums and
inputs were also checked. A spent output is excluded by input resolution.

Two self-payments were submitted and confirmed:

- `a3453280e6e7ac2c7078b344e91df6baf50ca86200969b65f1a67ec9a6935949`:
  inline datum, checked against its original value after retrieval.
- `c357d2dbae00d1226b4813372b87f76e3945a77e49b9f73553314e692a651f5f`:
  native and Plutus V2 reference scripts, retrieved through both address queries
  and input resolution with exact script-hash checks.

The first address query after the second confirmation returned an older UTxO
snapshot. A later read returned both expected outputs; confirmation does not
imply that every index endpoint has caught up.

A signed Plutus V2 mint was evaluated remotely without submission; the service
returned 8,400 memory units and 1,328,100 steps for minting redeemer zero.

The additional-UTxO evaluation check found and corrected a live-service encoding
incompatibility: the hosted evaluator rejects an ADA-only value containing an
empty `assets` object. Omitting that optional field preserves the same value and
allows evaluation. A differential request changed only that field, retaining the
same transaction, query version, datum fields and supplemental input. Nonempty
asset maps remain unchanged. A deterministic regression covers the ADA-only
payload alongside the existing multi-asset encoding test.

Follow-up validation passes all 498 tests (325 public, 125 runtime and 48
Blockfrost). The updated backend suite passes Valgrind with zero errors, zero
lost bytes and zero matched suppressions. The unchanged public/runtime suites
retain the earlier clean Valgrind runs. Package, formatting and lint checks pass.

The rebuilt public provider passed the final supplemental-input check: transaction
`aab7db0ee0a646ab66193cffd1f481b58b2312518b8721fe62bf81a8a453fce1` failed
evaluation without its synthetic input and returned 8,400 memory units and
1,328,100 steps when that exact input was supplied. This transaction was evaluated
only, never submitted.

### P14, first completeness pass: inspection and message interchange

The post-P13 audit checks the installed public headers at native commit
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`. It distinguishes missing domain operations
from immutable-value adaptations and stale planning records. This slice does not
complete P14 or declare every pending ledger entry implemented.

#### API review and caller workflows

- Transaction inspection uses explicit `Cometa.Transaction.Inspection` functions
  returning `IO (Either Error Aeson.Value)`. The caller assembles or decodes a
  typed value, inspects it, then renders the result with `Aeson.encode`.
  [cardano-api JSON serialization](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Serialise/Json.hs)
  demonstrates explicit schema serialization with structured decode errors;
  [Atlas transaction instances](https://github.com/geniusyield/atlas/blob/c3adfb416242ea25a244bfaa1614213eecdc55d9/src/GeniusYield/Types/Tx.hs)
  instead use CBOR-hex JSON strings. Cometa deliberately does not install global
  instances that would confuse inspection with transaction interchange.
- CIP-8 message signing uses the existing scoped `SigningKey`, a validated address
  or key-hash binding, and binary payload. It returns owned COSE Sign1 and key
  bytes. The actual [cardano-addresses signing workflow](https://github.com/IntersectMBO/cardano-addresses/blob/5bca1736741413802f5b5aa96d0be9747f89f03c/lib/Cardano/Address/Derivation.hs)
  informed opaque-key/message composition; it is not a COSE implementation.
  [CIP-8](https://cips.cardano.org/cip/CIP-0008) defines the message representation.
  Cometa retains IO and scoped native keys. The pinned native API signs nonempty,
  unhashed payloads with empty external AAD; `_ex` selects key-hash binding. Neither
  operation proves that the supplied address/hash belongs to the key. The public
  contract and independent verification tests state this explicitly. The encrypted
  software handler is unchanged because its native interface has no message method.
- Asset identifiers import/export policy bytes followed by exact name bytes.
  [cardano-api's AssetId model](https://github.com/IntersectMBO/cardano-api/blob/5e63165a4bb7481a03d2e50464dc9c4f106c9fa5/cardano-api/src/Cardano/Api/Value/Internal.hs)
  separates Ada from native tokens; its dotted text grammar is not silently used
  for native contiguous hex. Successful native codecs round-trip. Ada is explicitly
  unsupported in these codecs rather than exported as an empty value that cannot
  be imported. Fingerprints follow the [CIP-14 Haskell reference and vectors](https://github.com/cardano-foundation/CIPs/blob/86b89208d3b2aabb5dcc5b778dfbe09096b4e114/CIP-0014/README.md):
  BLAKE2b-160 of policy/name bytes followed by Bech32 with the `asset` prefix.
  Fingerprints are display identifiers, not reversible or authenticity proofs.
- `Protocol.Parameters.Update.toPlutusData` converts a typed sparse update into
  the changed-parameter script-data map. The reviewed [ledger caller](https://github.com/IntersectMBO/cardano-ledger/blob/7827506b7518284d7f9dbbe3502a20431e513fe9/eras/conway/impl/src/Cardano/Ledger/Conway/TxInfo.hs)
  passes `toPlutusData` into V3 `ChangedParameters` for a parameter-change action.
  Cometa uses a named operation rather than adding a generic conversion class,
  and retains IO because the native conversion allocates. It differs from ledger
  update CBOR: rationals are reduced lists, null alternatives are constructors,
  and historical keys 12–14 are omitted. It does not validate era activation rules.

#### Ownership and conformance

Inspection parses fresh native objects from borrowed input bytes, requires a
complete CBOR value, writes JSON, copies the owned result and releases all native
owners. Returned Aeson values are independent of those owners. Original body bytes,
transaction IDs and witnesses remain unchanged. The JSON writer buffer contains
length-delimited bytes without a terminating NUL; no terminator is guessed or removed.

CIP-8 borrows the key under its existing operation lock. Both output slots are
initialized and bracketed before the safe native call; partial native failures,
copy exceptions and cancellation release both outputs. Temporary address/hash
owners are released in C. Tests cover both key formats, exact native vectors,
independent COSE structure and Ed25519 verification, mismatched bindings, empty
payloads, closed keys, lazy failures, repeated calls and concurrent independent scopes.

Protocol conversion releases its temporary update, data and writer before returning
one owned CBOR buffer. The Haskell boundary copies and releases that buffer before
materializing public Plutus data. Asset codecs acquire no native resource;
fingerprinting uses the existing scoped hash implementation.

Fixture provenance is recorded in `test/Fixtures/INSPECTION.md`,
`test/Fixtures/PARAMETER_DATA.md`, and the CIP-8/AssetId test modules. Inspection
compares whole expected JSON values from all three pinned binding transaction
fixtures and two rich native transaction fixtures. It also checks each nested
body/subtransaction, arbitrary large signed integers, binary values, malformed
input cleanup, retained results across GC and concurrent inspection. Asset tests
include all eight official CIP-14 vectors and native codec correspondence for all
33 valid asset-name lengths. Protocol tests check rational reduction, execution-unit
ordering, null distinctions, unsigned-64-bit values, all supported parameter IDs,
unchanged source bytes and repeated conversions.

The ledger reconciles 23 explicitly reviewed entries in this slice: six asset-codec
operations, ten stale address mappings, four inspection operations, two CIP-8
operations and one protocol conversion. No test-only oracle is counted as production
coverage, and no native fingerprint symbol is invented.

#### Remaining completeness and release gates

A subsequent pass must address governance identifier text (CIP-105/129 and checked
index bounds), standalone Value CBOR and remaining algebra, standalone JSON codecs,
language-view encoding and remaining general CBOR capabilities. The large pending
count also contains buffers, integers, mutable collection machinery, diagnostics
and lifetime operations: each needs a justified correspondence or omission, not a
mechanical public wrapper or a blanket status change.

The lifecycle review found no demonstrated defect in the inspected callback and
native evaluation paths. Existing tests cover cancellation, reentry, lazy results,
retained aliases, grouped rollback and V1–V4 evaluation. Performance review still
needs measured build/sign/inspect, startup and marshaling baselines. The Blockfrost
manager deliberately disables idle pooling for deterministic connection cleanup;
no ownership change is justified by unmeasured assumptions. Published-package
consumer validation and release publication remain P15 work.


#### Integrated validation for this slice

GHC 9.6.7 builds all components and passes all 518 tests: 339 public, 131 runtime,
and 48 Blockfrost. Both changed public/runtime suites pass Valgrind with zero
errors, zero definitely/indirectly/possibly lost bytes and zero matched
suppressions. The unchanged Blockfrost suite retains its P13 clean Valgrind run.
The final CIP-8 test cleanup was recompiled and its six tests pass separately.
All four new/updated examples run successfully. Ormolu, HLint, ClangFormat,
`cabal check`, native inventory, strict Sphinx/link checks and both portable public
Haddock references pass; public declarations retain 100% documentation coverage.
The source-package manifest contains the new sources, fixtures, notices, guides
and examples. Hosted CI results are reviewed on the PR before another slice;
these local checks do not by themselves establish the platform matrix.

### P14 example parity and upstream capability audit

The next review slice ports all 21 examples from Cometa.cpp revision
`824ae8e8ac9adf113d957265532ae7ea37a628a3`. The exact source-to-entrypoint mapping,
intentional configuration differences and execution evidence live in
[the example parity record](EXAMPLE_PARITY.md). Connected runners require an
explicit `--submit`; ordinary CI compiles them and exercises their credential-free
usage paths. Staking/governance recipes have offline tests, but ledger state and
on-chain acceptance must be validated independently on the selected network.

The [Haskell capability audit](HASKELL_API_PARITY.md) compares pinned current
sc-tools, Atlas, cardano-api and cardano-addresses sources. It extends the native
symbol ledger: that ledger cannot establish parity with a node client, emulator,
query service or code generator. Forty-two comparison groups distinguish
implemented, partial and missing application workflows from excluded
infrastructure. These are review groups, not a percentage denominator. Current cardano-api already includes experimental
Dijkstra support; the comparison does not claim otherwise.

The [delivery scope](HASKELL_API_PARITY.md#delivery-scope-native-coverage-and-idiomatic-transaction-construction)
now determines completion: existing cardano-c domain coverage, all native-supported
transaction constructions and small idiomatic Haskell conveniences. Complete the
shared current-treasury-value and explicit/deferred proposal redeemer builders;
reconcile the remaining symbol ledger using tested public equivalents rather than
C-shaped wrappers. Expand the README with compiled examples across supported eras.

Broader provider queries, standards absent from C, blueprints, upstream interop,
CIP-8 verification and advanced VM tooling are future work. Seed generation and
larger infrastructure remain excluded. Do not describe this narrower scope as
full upstream-library parity. Record named acceptance tests and specific omissions.

For each slice, review upstream source before API design, use idiomatic public
values, preserve cancellation/resource safety, and add cross-library or independent
vectors where possible. Native-oracle tests establish binding correspondence;
independent ledger acceptance and upstream behavior need their own evidence.

Local validation for this slice: GHC 9.6.7 builds every component. The 352 public,
131 runtime and 48 Blockfrost tests pass; the HTTP tests require loopback sockets.
The public suite passes Valgrind with zero errors and zero definitely, indirectly
or possibly lost bytes. After the deferred recipe alignment, all 31 matching
native tests pass again and the changed end-to-end workflows pass Valgrind again.
All 17 connected entrypoints print usage without credentials, and the five
recovery/swap/evaluation/deferred/Dijkstra offline programs run successfully.
Ormolu, HLint, package checks, source manifest, native inventory, strict Sphinx
HTML/link checks and both public Haddock references pass. Live execution results
are maintained separately in the example parity record.

Live V2 staking exposed duplicate script witnesses when independently composed
certificate plans each attached the same script. Native evaluation succeeded,
but the ledger rejected the duplicate CBOR set elements before execution. Shared
plan normalization now coalesces attachments by language and script-hash preimage,
retaining the first encoding and order. Both top-level and subtransaction builders
use that normalization. Regressions cover native and V1–V4 scripts, distinct
versions/programs, nonminimal outer Plutus framing, a used V2 witness and an
actually evaluated V4 subtransaction. No cardano-c change is required by this fix.

After the script-attachment fix, all components rebuild and all 533 tests pass
(352 public, 133 runtime, 48 Blockfrost). The full runtime suite and all 11
connected governance recipe tests pass Valgrind with zero errors and zero lost
allocations. The public full-suite result above remains the broader lifecycle
baseline; these targeted reruns exercise the changed normalization and live recipe.

The related datum path also appended repeated witness data. Normalization now
coalesces exact datum CBOR across explicit attachments and input arguments, after
checking the original per-input declarations. Distinct hash-bearing encodings,
input order and deferred callback indices remain unchanged. All components build
and all 535 tests pass (352 public, 135 runtime, 48 Blockfrost). The 135-test
runtime suite passes Valgrind with zero errors and zero lost allocations. The
[PR validation record](https://github.com/Biglup/cometa.hs/pull/22) holds per-run
preprod transaction and cleanup evidence separately from these deterministic checks.

### Native construction completion and Haskell conveniences

The [construction coverage record](TRANSACTION_CONSTRUCTION.md) maps the narrowed
scope to public APIs and named test modules. Proposal and treasury API design
reviewed cardano-api's ordered proposal witnesses and current-treasury setter
before choosing matching operations in the existing plan monoid. Top/sub proposal
callbacks retain local insertion indices and protocol deposits; policy-less actions
require no evaluator. Shared functionality belongs in cardano-c, with a pinned
native revision for reproducible builds.

Standalone credential and digest CBOR uses pure checked semantic values. Invalid
kind, shape, length and trailing input remain explicit failures. Existing encoding
identity contracts for imported transactions are unchanged. New API-specific
upstream reviews and final validation evidence are recorded below as integration
completes; this section does not claim unrun checks.

#### Existing-domain API review

Value/codecs reviewed cardano-api `c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a`
(`Value/Internal.hs`) and Atlas `c3adfb416242ea25a244bfaa1614213eecdc55d9`
(`Types/Value.hs`, `Types/Governance.hs`, `Types/DRep.hs`) before API design.
Their callers assemble normalized signed maps and convert at checked ledger
boundaries. Cometa similarly keeps arbitrary-precision algebra pure, while
standalone native Value/mint CBOR checks signed native storage bounds. DRep text
imports CIP-105 and CIP-129 with explicit prefix/header validation; action text
rejects the native display format's index narrowing. `intersection` is an ordinary
left-biased signed-map operation, not a disguised minimum or coin clamp.

Native-script JSON follows the actual cardano-c construction schema, including
its guard keyHash/scriptHash forms. Metadata plain JSON is a separate checked
conversion from detailed metadata JSON and CIP-116 inspection: bytes, nontext keys
and duplicate object keys fail rather than lose information. These helpers add
no production native resources; test oracles rebuild typed public values.

Building utilities reviewed cardano-api's `Tx/Internal/Fee.hs` and
`Tx/Internal/Body.hs` at the same revision: actual witness sizes, reference script
bytes and execution-unit prices are separate inputs. Pure size queries and exact
`executionFee` retain that distinction; existing `minimumFee` remains the combined
checked protocol-aware operation. Language-view encoding follows the historical
V1 encoding and known V1–V4 ordering, with caller-selected cost models. Tests
compare every language subset and integer boundary against native oracles.


#### Windows HTTP fixture shutdown

The previous PR22 Windows job timed out in the local HTTP fixture after the public
suite had passed. Reviewed haskell/network
[`v3.2.12.0`, Socket/Syscall.hs](https://github.com/haskell/network/blob/v3.2.12.0/Network/Socket/Syscall.hs):
threaded Windows performs `accept` through a safe blocking FFI call. Cancelling
that worker before closing its listener can wait indefinitely. The test fixture
now closes sockets before cancellation and joins all workers with bounded waits.
Accepted sockets are acquired while masked and registered before handlers are
unmasked. No production provider transport behavior changes.

All 49 Blockfrost tests pass locally. The final masked-acquisition form passes 20
concurrent stress runs, including 400 idle-listener cleanup cycles. Windows CI
must confirm the platform-specific result; Linux execution alone is not evidence
that Windows has passed.


#### Integrated validation of construction/domain completion

All components build on GHC 9.6.7; all 554 tests pass (362 public, 143 runtime,
49 Blockfrost). Each complete suite passes Valgrind with zero errors and zero
bytes definitely, indirectly or possibly lost. All 54 credential-free example
entrypoints run successfully, including offline scripts, governance and batches;
connected runners print usage and do not submit. README Haskell blocks compile
with `-Wall -Werror`. Ormolu, HLint, ClangFormat 18, package checks, native inventory,
source manifest, strict Sphinx HTML/link checks and both portable Haddock references
pass. Native prerequisite PR222 has 1,044 relevant local tests and seven focused
allocation/ownership tests clean under Valgrind. Hosted matrix status remains a
separate gate; Windows must confirm the fixture shutdown correction.

Cometa.Inspection adds named domain operations instead of global JSON instances.
Its 24 new operations cover values, scripts, credentials, certificates, governance,
pool/protocol values, data, witnesses and metadata. Typed corpus projections check
exact schema correspondence; malformed, truncated and trailing input, cleanup,
GC survival and concurrency cover every dispatch operation. Inspection is not
an inverse serialization or a ledger validity check.

The ledger reconciles source-confirmed existing equivalents rather than reporting
raw pending row count as missing user features. Lifecycle delegations were checked
against native function bodies; no clone, cache or tag operation was blanket
classified as plumbing. Remaining collection encodings and representation choices
are recorded in TRANSACTION_CONSTRUCTION.md for the next completeness slice.
The existing preprod record predates the new native pin; no additional on-chain
execution is claimed by this validation.
