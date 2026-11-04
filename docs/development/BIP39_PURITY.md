# Audited BIP39 purity exception

Reviewed 2026-11-05 for native pin
`7a65f2c7309bbba9e86f6aa73214b003fab88aee`. This exception covers only
`Cometa.Internal.Bip39Pure`'s three concrete monomorphic native boundaries:
`fromEntropy`, `fromWords`, and `exportEntropy`. `fromText` is pure splitting
followed by `fromWords`. It authorizes no other native operation or generic
`IO a -> a` helper. Keep providers, callbacks, key lifetimes and arbitrary
allocation/mutation in `IO`.

The pin update adds initialization locking and password-crypto validation.
The BIP39, SHA256 and wipe-helper sources are unchanged from the original
`8dc0c55f4132fcaa2e7961b6cfbfea96a6d93b5d` review; the threading build change is
reviewed below.

The latest pin adds secret-buffer wiping in BIP32 root derivation and Ed25519
signing, plus key-handler storage validation. Those operations are outside this
pure boundary. The reachable hashing, PBKDF2, BIP39, error and wipe-helper sources
and native build configuration are unchanged from the prior
`7811fe94dad90f30478ed4b61d96677f188abaa8` audit.

## Reachable native code

- `lib/src/bip39/bip39.c`: standard bounds (16/20/24/28/32 bytes,
  12/15/18/21/24 words), stack scratch, bounded loops, `strcmp`, `memcpy`,
  `cardano_safe_memcpy`, bundled `crypto_hash_sha256`, static English words.
  No logger, configured allocator, RNG, callback, reference counting,
  initialization requirement or mutable error state is reached.
- `lib/src/bip39/bip39_wordlist_en.h`: translation-unit-private pointer slots
  refer to literal strings; this source never writes the slots.
- `lib/src/string_safe.c`: the reachable `cardano_safe_memcpy` only guards
  null/bounds and copies bytes. Other functions' errno/stdio paths are not reached.
- `lib/external/libsodium/crypto_hash/sha256/cp/hash_sha256_cp.c`: init/update/final
  use stack state and constant tables, no implementation dispatch or sodium
  initialization, and always return success. Native BIP39 ignores SHA256 status;
  replacing this implementation requires review of that assumption.
- `lib/src/error.c`: `cardano_error_to_string` returns static literals by switch;
  the C adapter introduces no additional state.
- `lib/src/cardano.c` and bundled `sodium/utils.c`: `cardano_memzero` guards and
  forwards bounded writes to `sodium_memzero`. SHA256 also uses this wipe.
  Native checksum failure writes entropy before returning: the wrapper wipes
  all 32 scratch bytes even on error and never copies failed entropy out.

The inspected Linux x86-64 objects call only the audited helpers, memory/string
operations and compiler memory/stack-check helpers. They contain no allocator
or logger reference on this path.

## Native build and platform review

`tools/build-native.py` builds the pinned static target with IPO disabled.
The native CMake configuration defines `SODIUM_STATIC` and, on native Unix,
`HAVE_PTHREAD=1` for initialization locking. It defines no wipe-selection sodium
feature macros. On the reviewed Unix configuration `sodium_memzero` therefore
uses bounded volatile stores; disassembly confirmed that branch locally.
The threading flag changes `sodium_init`, which this BIP39 call graph never
reaches; it does not change SHA256 or the selected wipe implementation.
Linux ARM and macOS ARM/Intel select the same source fallback under this build.
Windows selects the Windows-header `SecureZeroMemory` bounded wipe when `_WIN32`
and not `__CRT_INLINE`, otherwise the same fallback. These are source reviews;
local execution evidence is Linux x86-64 only. CI must supply execution evidence
for its existing Linux x86-64/ARM, macOS ARM/Intel and Windows matrix.

Custom native builds may select `memset_s`, `explicit_bzero`, `memset_explicit`,
`explicit_memset`, or a weak dummy-symbol path. They are outside this reviewed
build contract: the `memset_s` failure path can reach `sodium_misuse`, and the weak
symbol can be interposed. Re-audit reachable code, selected macros/objects, SHA256,
wiping, linkage and diagnostics whenever the native pin, compiler/platform,
build flags or dependency implementation changes. A source pin by itself is
not sufficient evidence for arbitrary native build variants.

## Haskell boundary and evaluation

`Mnemonic` remains an opaque words-only value, with no `Show` or equality
instance, retained native owner, or hidden entropy copy. The private module uses
`unsafePerformIO` with `NOINLINE` on each concrete boundary and local `-fno-cse`
and `-fno-full-laziness`, following base's optimizer safeguards. There is no
`unsafeDupablePerformIO` and no exported arbitrary IO runner. These safeguards
are not the proof of purity: deterministic behavior and independence from
external mutable state on the audited path are essential.

Input buffers live through safe, non-interruptible foreign calls. Static words,
UTF-8 and entropy outputs are copied and forced before the operation returns;
word decoding is forced inside its scoped marshaling action. The full retained
word-list spine and each strict `Text` are forced directly, without exporting an
extra phrase. Entropy copies and complete public error payloads are forced before
the unsafe IO boundary returns. Exact unexpected native statuses, diagnostics
and contract failures remain `Either` values; no partial getter or impossible
status fallback is introduced.

The existing `finally` wipe runs on success/failure and asynchronous cancellation
after foreign unwind. Pure evaluation promises neither execution count nor
execution timing: calls may share, be duplicated, or restart after cancellation.
The audited path is safe under those choices. Sharing may extend secret
retention. No comprehensive erasure guarantee is made for Haskell values or
native stack intermediates.

## Regression evidence

The suite retains all 26 independently crosschecked vectors and exact invalid
input/domain errors. It adds concurrent workers contending on one shared result,
varied entropy conversions with GC before entropy export, varied repeated unknown
word failures, and cancellation followed by a fresh conversion. Cancellation is
a scheduling smoke test: these bounded C calls are too short to guarantee an
exception arrives during native execution. The CI matrix runs the BIP39 group
at `-O2` with two capabilities, in addition to the ordinary complete suite.

Local production validation and runtime findings are recorded in the
implementation plan. The earlier spike's `-N4` Valgrind loss was independently
reproduced by an empty threaded GHC 9.6.7 executable (16 bytes/four blocks in
`initCapabilityIOManager`); this must not be called a clean Valgrind run or used
to dismiss unrelated findings. An earlier unreproduced 288-byte possible loss
without a captured allocation stack remains unclassified.
