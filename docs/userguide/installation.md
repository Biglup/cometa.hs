# Installation

[Cometa 0.2.0.0](https://hackage.haskell.org/package/cometa-0.2.0.0) is available
on Hackage. It depends on the exact native companion version
[cardano-c-clib 0.1.1.0](https://hackage.haskell.org/package/cardano-c-clib-0.1.1.0),
which builds the bundled cardano-c v2.0.0-rc.7 sources. You need GHC, Cabal and
a C toolchain. Consult the package description for compiler and dependency bounds.

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

The Hackage distribution uses the same native source dependency. Cabal downloads
and builds it automatically; no checkout preparation command is needed when
using the published packages.

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

Add `cometa ==0.2.0.0` to your component's `build-depends`, then run:

```sh
cabal update
cabal build
```

To use a checkout instead, add the Cometa.hs directory and its prepared
`.native/cardano-c-clib` directory to your application's Cabal project. Pin source
revisions for reproducible builds. See the [API reference](api-reference.md) for
declarations and local Haddock generation.

## Blockfrost

`Cometa.Provider.Blockfrost` is included in `cometa`; no additional package or
library component is required. It uses the same transaction values and
`Provider` interface as application-defined providers.
