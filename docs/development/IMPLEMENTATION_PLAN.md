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
refinements also run under the focused domain memory check.

The ledger now records 621 implemented/adapted entries across the binding,
compared with 341 before this batch. This is symbol coverage, not an estimate of
remaining engineering effort. Native lifetime plumbing retains internal
visibility without being counted as implemented. Plutus/script JSON and native
metadata natural/CIP-116 JSON remain pending; auxiliary-data transaction
integration and full VM evaluation are separate work. Hosted compiler/platform
validation is tracked on the PR and is not implied by the local Linux results.
