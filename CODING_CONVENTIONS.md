# Haskell coding conventions

These rules apply to Cometa.hs. They turn the engineering requirements in
`docs/development/IMPLEMENTATION_PLAN.md`, section 19, into review criteria.
Use the checked-in formatter and HLint settings as the mechanical source of truth.

## Modules, layout, and imports

Use Ormolu 0.8.0.2 and HLint 3.8 with the repository's HLint configuration. Prefer readable
named arguments and pattern matching over dense point-free expressions. Use
normal Haskell layout, not Allman braces or C++ region markers.

Every module has an explicit export list and a Haddock introduction explaining
its domain. Group public exports by construction, inspection, transformation,
serialization, and effects when those groups help navigation. Keep public modules
focused; `Cometa` is a curated convenience module, not an indiscriminate re-export
of internals. Files follow the module hierarchy.

Give every public binding a type signature. Give internal helpers signatures when
they explain constraints or prevent unintended polymorphism. Prefer explicit
import lists; qualify domain modules with names such as `Address`, `Tx`, `Plan`,
or `Blake2b`. Do not use a custom Prelude or require an effects framework for
ordinary use. Avoid orphan instances; optional interoperability uses owned wrappers.

Use the package's declared language baseline. Enable an extension in the module
that needs it, with an explanatory comment when its safety or API consequences
are not obvious. Do not add package-wide extensions casually. Use ordinary record
selectors; do not introduce `DuplicateRecordFields` or `OverloadedRecordDot`
without a repository-wide decision and compiler-matrix evidence.

## Naming

- Modules, types, classes, and constructors use `UpperCamelCase`; functions,
  fields, variables, and constants use `lowerCamelCase`.
- Prefer domain names and qualified module vocabulary. Do not repeat `cometa` or
  mechanically expose C prefixes, getters, and setters.
- Use `fromBytes`/`toBytes`, `fromText`/`toText`, and `decodeCbor`/`encodeCbor`
  consistently. The type signature, not the name, determines effects.
- Use `mk...` for validated construction from a more general value. Return an
  explicit error; do not shorten call sites with partial smart constructors.
- `with...` scopes a resource. `run...` interprets an action. `eval...` and
  `exec...` follow the familiar distinction between returning a result or state.
- Prefer observers such as `fee` or `networkId` in qualified modules.
- Suffix `_` means a result is discarded. An apostrophe marks a documented variant,
  usually strictness, not an unexplained error policy. Use `By` for supplied
  comparison behavior and `On` for projection behavior where appropriate.
- Keep `TxId`, `Utxo`, and `Cbor` consistent. Prefer complete domain names over
  unexplained abbreviations. Exported unqualified record fields receive a domain
  prefix when needed to avoid ambiguity.
- Reuse lawful standard operators. A new symbolic operator needs a demonstrated
  readability benefit, a named equivalent, and documented fixity.
- Private FFI names may retain C spelling with an internal prefix for auditing;
  this vocabulary must not determine public Haskell names.

## Values, invariants, and laws

Use algebraic data types for alternatives and validated newtypes for invariants.
Hide constructors when they protect bounds, byte lengths, original encodings,
roles, or resource ownership. An exported record update or representation
conversion must not bypass those protections.

Audit every instance. `Read`, `IsString`, `Num`, `Generic`, and `Data` can expose
construction routes that violate invariants; justify their use individually.
`Show` is diagnostic, not a stable interchange format. Never derive secret-bearing
`Show` output. Role-indexed hashes and keys need a `Coercible` audit, nominal
roles where required, and compile-fail checks for the intended boundary.

Introduce a class only for a coherent abstraction with meaningful instances and
laws. Runtime providers, evaluators, selectors, and signers initially use records
of functions. Test every advertised law, including associativity and identity for
plan composition. Do not claim a total numeric monoid when bounded arithmetic
can fail. Optional optics must preserve invariants and obey their laws; a
normalizing or validating operation is not automatically a lawful lens.

Use `Integer` for arbitrary-precision protocol integers. Keep signed quantities
signed; validate nonnegative amounts and native bounds before conversion. Never
route monetary values through floating point. Do not derive unrestricted `Num`
for validated quantities.

Choose collections by their semantics. Preserve order, duplicate keys, absence,
null, empty, and zero wherever the format distinguishes them. Do not automatically
replace arbitrary Plutus maps with `Data.Map`. Define equality and ordering for
encoded values explicitly; pointer identity is not domain equality.

## Totality, effects, and evaluation

Expected invalid input returns `Either` with a structured domain error. `Maybe`
means legitimate absence. Native/effectful operations initially return
`IO (Either ... ...)`. Preserve error codes and context without leaking secrets.
Do not make a universal Cometa monad mandatory; callers may compose with `ExceptT`.

Normal public input handling must not rely on `error`, `undefined`, `fromJust`,
unchecked indexing, or incomplete patterns. Genuinely necessary unsafe operations
belong in an explicitly separated internal/unsafe surface with preconditions and
safe alternatives. Keep validation, composition, and materialized-value inspection
pure where practical. Native calls remain in `IO` until a specific purity review;
`unsafePerformIO` is not a shortcut.

Use strict accumulators and snapshots where needed to bound retention or keep
exceptions inside cleanup scopes. Do not enable blanket strictness without
justification. Strict fields and strict maps force particular structures only to
WHNF; nested values and functions may remain lazy. Specify which callback result
parts must be forced before returning to C. `NFData` on a surrounding record does
not establish that a function has been fully evaluated.

Preserve ordinary asynchronous cancellation after safe foreign-boundary unwind.
Use structured, bounded concurrency. A timeout is not evidence that C stopped
using its buffers or callback state. Measure marshaling, allocations, startup,
and evaluation before adding specialization or unsafe optimization.

## FFI and resource safety

Separate raw declarations, marshaling, ownership scopes, and callbacks. Audit the
current native headers and implementation rather than assuming that all getters
borrow or all outputs transfer ownership. Record contracts in the API ledger.

- Copy borrowed bytes/strings or retain an immutable owner for their entire use.
  Retaining a reference is not cloning; native reference counts are not atomic.
- Track every ownership obligation explicitly. After unref, mark the local
  obligation released even if another owner leaves the pointer non-null.
- Copy native diagnostics before releasing their owner. Release operation-scoped
  resources deterministically on all exits; finalizers are a fallback for suitable
  persistent resources.
- Access managed pointers through `withForeignPtr`. Typed pointer-to-pointer C
  unref functions cannot serve directly as unary `ForeignPtr` finalizers.
- Keep callback closures rooted with supported stable handles. Keep `StablePtr`,
  `FunPtr`, contexts, and error state alive through the last possible callback,
  including repeated balancing and cleanup.
- Distinguish provider/key-handler context adoption from borrowed deferred contexts.
  Retain operation owners while callbacks run. Prevent unsupported reentry.
- Use callback-capable `safe` imports when C can re-enter Haskell. Audit short,
  non-callback `unsafe` imports individually; account for scheduler behavior in
  long-running evaluation. Do not mark arbitrary calls `interruptible` for timeouts.
- Bracket/mask ownership transitions. Catch callback exceptions within the bridge,
  return a native failure, and rethrow or translate after safe unwind. Do not
  silently turn asynchronous cancellation into a recoverable provider error.
- Concurrent operations have independent mutable handles and error slots, or a
  documented synchronization scheme. A worker continuing after cancellation owns
  and eventually releases all state it still uses.

Hash-bearing transaction values must preserve original encoding where identity
requires it. Controlled edits invalidate affected caches and define witness
behavior. Never silently canonicalize a signed transaction. Establish exact CBOR,
body-hash, signature, and edit-independence tests before broad implementation.

Secret resources are opaque and scoped. Reject use after close, including escaped
handles; a callback-shaped acquisition alone does not prove safety. Private-key
export must be explicit and explain the loss of controlled lifetime after copying.

## Documentation and tests

Public Haddock describes observable behavior: meaning, parameter units and bounds,
return values, errors, defaults, ordering, and effects. Each public module explains
its purpose and has a small valid example. Keep raw ownership mechanics internal.
Use the Microsoft Writing Style Guide as an editorial reference and established
Haddock syntax for declarations. Narrative pages teach tasks; proposed interfaces
stay in developer plans and must be labeled as proposals.

Compile executable examples and check links. Use pure deterministic doctests when
appropriate and compiled fixtures for effectful flows. Never require credentials
for ordinary documentation builds. Keep the guide and versioned Haddock aligned
with the source/package they describe.

Prefer Hedgehog for new shrinking and state-machine properties; retain imported
QuickCheck properties when practical. Test laws, bounds, invalid encodings,
round trips, collection semantics, snapshot independence, allocation baselines,
callback rooting, exceptions, repeated callbacks, cancellation, and supported
concurrency as relevant. Use deterministic fakes for injected components. Selector
tests assert invariants rather than identical random choices. Save minimized
failures as regression cases.

Pin native/corpus revisions and record imported test source paths, commits, and
licenses. Test through public values, not only opaque CBOR forwarding. Native
agreement detects binding errors; use independent vectors or oracles where
possible. Keep authorized live-network evidence separate from fixture evidence.

## Native adapters

Keep C adapters in `cbits` limited to ABI layout, ownership, and marshaling.
Use the checked-in `.clang-format` with ClangFormat 18, matching cardano-c's
formatting. Haskell keeps its own Ormolu conventions. Document adoption, borrowing,
callback lifetime, and failure ownership at each boundary. Native callbacks must
never unwind a Haskell exception through C.

## Compatibility and review

Follow the Haskell Package Versioning Policy for exposed types, declarations,
instances, and dependency bounds; track native version/ABI separately. Test the
supported compiler matrix and dependency bounds. Use meaningful warnings,
including incomplete patterns and record updates. CI may promote warnings to
errors; do not ship unconditional `-Werror` to consumers.

Before bulk implementation, review complete use cases for payment, script spend,
custom evaluation, external signing, decoding failure, and cancellation. Before
first release, seek experienced Haskell/FFI maintainer review when available and
record its outcome. Passing automated checks does not prove exception safety or
API quality.

The reference set and rationale are maintained in implementation-plan section 19:
containers, text, async, Hasql, Megaparsec, optics, Hedgehog, the Kowainik naming
guide, Google Haskell style guide, and the Haskell PVP. Adopt the specific contracts
that fit this library rather than copying historical partial APIs or dependencies.
