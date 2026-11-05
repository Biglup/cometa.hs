# PBKDF2-HMAC-SHA512 purity audit

Reviewed 2026-11-05 against native revision
`7a65f2c7309bbba9e86f6aa73214b003fab88aee` and the existing pinned static native
build. This is a separate, narrow exception alongside BIP39; it does not authorize
pure wrappers for arbitrary native operations or EMIP3.

The latest pin adds secret-buffer wiping in BIP32 root derivation and Ed25519
signing, plus key-handler storage validation. Those operations are outside this
pure boundary. The reachable hashing, PBKDF2, BIP39, error and wipe-helper sources
and native build configuration are unchanged from the prior
`7811fe94dad90f30478ed4b61d96677f188abaa8` audit.

## Reachable native path

`lib/src/crypto/pbkdf2.c` borrows password/salt, writes only the caller's derived
key buffer, and uses local HMAC state, block digests and counters. It allocates no
native owner, reads no allocator configuration, mutable global state, error slot,
RNG or logger, and invokes no callback. `lib/src/string_safe.c`'s bounded memcpy
and `lib/src/endian.c`'s counter encoding are deterministic. All native expected
validation failures precede output computation; public validation excludes zero
salt/output, zero iterations and overflowing block/counter ranges.

`lib/external/libsodium/crypto_auth/hmacsha512/auth_hmacsha512.c` initializes,
updates and finalizes caller-supplied SHA512 states. Its separate random keygen
function is unreachable. `crypto_hash/sha512/cp/hash_sha512_cp.c` uses stack state
and static constant tables without runtime dispatch. HMAC intermediate states
and PBKDF digests are wiped by native sodium_memzero. Public cardano_memzero
forwards to that bounded wipe. Its selected platform branches and build-variant
restrictions are the same ones audited in BIP39_PURITY.md: this build defines no
wipe-selection sodium HAVE_* feature macros, selecting volatile writes on Unix
or Windows SecureZeroMemory where enabled. HAVE_PTHREAD protects unrelated
initialization and RNG paths; it does not change this call graph. No sodium_init is reached or required by this
stateless path. Initialization of unrelated native crypto cannot change results.

The RFC block limit is `64 * (2^32 - 1)` output bytes. Output must also fit Haskell
Int. The iteration maximum is the complete uint32 range, `2^32 - 1`; native
iteration starts at one and compares strictly below the requested count,
preventing counter wrap on 32-bit targets. These are representation limits,
not advice to perform enormous derivations.

## Haskell boundary

Only monomorphic `Cometa.Internal.Pbkdf2Pure.deriveBytes` uses unsafePerformIO,
with NOINLINE, -fno-cse and -fno-full-laziness. No polymorphic IO runner or
unsafeDupablePerformIO exists. These optimizer safeguards supplement the native
state-independence audit; they do not replace it. Public validation remains pure.

Password/salt ByteStrings are borrowed in nested useAsCStringLen scopes. Heap
scratch is allocated with Haskell mallocBytes and bracketed before computation;
cardano_memzero and free execute on success, failure, copy exceptions and
cancellation after native unwind. Scratch is not input-sized stack storage. Safe,
non-interruptible FFI ensures no C operation continues using released buffers.
The strict ByteString result is copied and forced within the scratch scope;
complete public error payloads are forced before the concrete pure boundary
returns. Native diagnostics are static and copied before return. Unexpected
native statuses and contract errors remain structured Either values.

Host allocation exhaustion may raise an exception, as with ordinary pure
ByteString allocation. Evaluation can be shared, duplicated or restarted;
results and ownership are valid under each choice. No execution count/timing
promise is made. Cancellation may wait for the whole derivation. Shared thunks
can retain password/output values longer. Ordinary immutable Haskell inputs and
explicit secret output copies are not erased or protected from logging.

## Regression and re-audit

Tests retain a native known answer and an independent Python hashlib binary
multi-block answer, output-prefix properties crossing the 64-byte block boundary,
invalid bounds, empty passwords, cancellation followed by reuse, and shared
concurrent evaluation/GC. Native buffer ownership tests concern EMIP3 separately.
Cancellation is a scheduling smoke test, not proof the exception arrived inside C.

Re-audit the full reachable graph, build flags, wipe implementation, diagnostics,
linkage and marshaling whenever the native pin, native dependency implementation,
compiler/platform or build flags change. Custom builds selecting additional
sodium feature macros are outside this review. Local execution is Linux x86-64;
existing hosted compiler/platform matrix results must be reviewed independently.
