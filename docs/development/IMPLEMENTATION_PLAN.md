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

Use Cabal with explicit dependency bounds and tested GHC versions. Evaluate
`hsc2hs` or equivalent header-derived declarations for ABI sizes/offsets. Do not
select a generator solely because it emits function declarations: ownership still
needs manual auditing. Any C shim must be small, documented, and tested.

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

The first foundation is under review in [PR #1](https://github.com/Biglup/cometa.hs/pull/1).
It covers the initial P00/P01 foundation and a small P02/P04 hashing slice. Read `AGENTS.md`, `CODING_CONVENTIONS.md`, the current CI results,
and `native-api.csv` before continuing. The ledger inventories 3,881 declarations
from 231 public headers; presence in that inventory does not mean implemented.
`native/cardano-c.ref` pins the native source and `native-baseline.json` records
header/corpus provenance.

The initial public surface is `Cometa.nativeVersion`, structured errors, and
`Cometa.Crypto.Blake2b` construction, hashing, and byte/hex inspection. Native
operations use `IO (Either Error a)` and return copied Haskell values. This does
not yet establish the callback, secret-resource, or transaction ownership model.
Continue with the remaining ABI/ownership/cancellation prototypes before broad
crypto and encoding coverage. Hackage name availability, native distribution,
callback retention, and the full platform matrix remain acceptance gates.

Documentation uses Haddock for API contracts and Sphinx/MyST for the narrative
guide. Read the Docs needs project import; Hackage publication is a release task.
Neither hosted service is advertised as already published.

Local foundation evidence: GHC 9.6.7 builds with warnings as errors; ten tests
include 200 Hedgehog cases; Ormolu and HLint pass; all three public modules have
complete Haddock coverage; strict Sphinx and link checking pass. A clean extracted
sdist builds against the pinned native library, and the README example compiles
and runs. Full Valgrind checks, including cancellation, pass with zero errors and no lost
allocations using fair thread scheduling and two RTS capabilities. Hosted platform
results remain under review. No full phase completion or release readiness is implied by these checks.

Update this plan with decisions, PR links, tested revisions, results and remaining
work as implementation proceeds. Keep release-specific pins in implementation
metadata and test provenance, not in the general binding architecture guide.

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

### 19.6 Test reuse follow-up

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
