# API reference

Haddock is the authoritative declaration reference. It describes the modules,
types, arguments, return values, and errors implemented by a particular source
revision. The narrative guide explains how to use those declarations.

## Download a build

Open a successful [CI run](https://github.com/Biglup/cometa.hs/actions/workflows/ci.yml)
for your source revision and download a `haddock-` artifact. Extract the archive
and open `index.html`. GitHub requires sign-in to download artifacts.

## Generate locally

With the native dependency configured as for a normal build, run:

```sh
python3 tools/build-api-docs.py
```

Open `docs/_build/api/index.html`, then choose the core library or optional
Blockfrost provider. The archive keeps links between these components relative,
so it can be moved or shared. Third-party API links point to Hackage.

Keep the native include and library directories in `cabal.project.local` when
the native library is installed outside the default search paths. For ordinary
local browsing, `cabal haddock all` is also available.

## Availability

The library is unpublished, so there is no released online API reference yet.
Use the Haddock generated from the same source revision as your application.
A narrative guide build alone does not verify the Haskell package or its native
dependency.
