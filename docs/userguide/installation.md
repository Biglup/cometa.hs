# Installation

Cometa.hs has not been released on Hackage. Build the checked-out source with
GHC and Cabal. Consult the repository's `cabal.project` and package description
for its current compiler and dependency bounds; a platform is supported only
when the corresponding CI build has passed.

## Native dependency

Install the cardano-c headers and library from the revision recorded in
`native/cardano-c.ref`. The manifest in
`docs/development/native-baseline.json` records the header and corpus baseline.
Headers and the linked library must come from the same compatible installation. Follow cardano-c's build instructions
for your platform.

When cardano-c is outside the compiler's default search paths, pass its installed
include and library directories to Cabal:

```sh
cabal update
cabal build all --extra-include-dirs=/path/to/cardano-c/include --extra-lib-dirs=/path/to/cardano-c/lib
cabal test all --test-show-details=direct --extra-include-dirs=/path/to/cardano-c/include --extra-lib-dirs=/path/to/cardano-c/lib
```

Replace the paths with the installation prefix on your computer. The include
directory must contain `cardano/cardano.h`. Keep the same native configuration
when building tests and Haddock.

## Runtime linking

A successful link does not ensure that the runtime loader can find a shared
library. Install cardano-c in a loader-visible location, or configure the loader
search path for your environment (`LD_LIBRARY_PATH` on Linux,
`DYLD_LIBRARY_PATH` on macOS, or `PATH` on Windows). Static installations may need
additional native dependencies at link time; follow the matching cardano-c build
configuration.

If headers cannot be found, check the include prefix. If linking fails, check the
library directory and architecture. If a built program fails to load cardano-c,
check the runtime search path and ensure it resolves the same library used during
compilation.

## Use in an application

Until a release is available, add the checked-out Cometa.hs directory to your
application's Cabal project and declare `cometa` in the application's
`build-depends`. Use an explicit source revision for reproducible builds. See
[hashes](hashes.md) for the current public interface and
[API reference](api-reference.md) for local Haddock generation.
