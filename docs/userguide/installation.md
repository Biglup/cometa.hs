# Installation

Cometa.hs has not been released on Hackage. Build the checked-out source with
GHC and Cabal. Consult the repository's `cabal.project` and package description
for its current compiler and dependency bounds; a platform is supported only
when the corresponding CI build has passed.

## Build a checkout

The default build compiles the pinned cardano-c source as the `cardano-c-clib`
Cabal dependency. You need a C toolchain as well as GHC, Cabal and Python 3 to
prepare a Git checkout. Obtain cardano-c at the revision recorded in
`native/cardano-c.ref`, then run these commands from the Cometa.hs directory:

```sh
python3 tools/package-native.py /path/to/pinned/cardano-c
cabal update
cabal build all
cabal test all --test-show-details=direct
```

The preparation command creates `.native/cardano-c-clib`, which the repository's
Cabal project includes automatically. No separate cardano-c installation or
include/library search flags are needed for this configuration.

The intended Hackage distribution uses a native source package dependency so
Cabal can build it automatically. Neither package is published yet; use the
checkout preparation above until release artifacts are available.

## Use an installed cardano-c library

To use an existing native installation instead, enable `system-cardano-c` and
supply its include and library directories when necessary:

```sh
cabal build all -fsystem-cardano-c --extra-include-dirs=/path/to/cardano-c/include --extra-lib-dirs=/path/to/cardano-c/lib
```

Use the revision recorded in `native/cardano-c.ref`. Headers and library must
come from the same compatible installation; the include directory must contain
`cardano/cardano.h`. Keep the flag and native paths when running tests or building
Haddock. The repository's `tools/build-native.py` helper selects this configuration
when preparing an installed native library for development.

For a shared installation, make the library available to the runtime loader
through the installation location or the environment's search path
(`LD_LIBRARY_PATH` on Linux, `DYLD_LIBRARY_PATH` on macOS, or `PATH` on Windows).
Static installations may need additional native dependencies at link time;
follow the matching cardano-c build configuration.

If headers cannot be found, check the include prefix. If linking fails, check the
library directory and architecture. If a built program fails to load cardano-c,
check that the runtime search path resolves the library used during compilation.

## Use in an application

Until a release is available, add the checked-out Cometa.hs directory to your
application's Cabal project alongside its prepared `.native/cardano-c-clib`
directory, and declare `cometa` in the application's `build-depends`. Use explicit
source revisions for reproducible builds. See
[hashes](hashes.md) for the current public interface and
[API reference](api-reference.md) for local Haddock generation.

## Blockfrost

Add the optional Blockfrost component when your application uses that backend:

```text
build-depends:
  cometa,
  cometa:blockfrost
```

The component supplies `Cometa.Provider.Blockfrost` and its HTTP/TLS dependencies.
Applications using another provider or working offline only need `cometa`.
Both components use the same transaction values and `Provider` interface.
