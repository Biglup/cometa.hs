# API reference

Haddock is the authoritative declaration reference. It describes the modules,
types, arguments, return values, and errors implemented by a particular source
revision. The narrative guide explains how to use those declarations.

## Generate locally

With the native dependency configured as for a normal build, run:

```sh
cabal haddock all
```

Cabal prints the generated HTML location under `dist-newstyle`. Open the package
index for the main library, then browse `Cometa`, `Cometa.Crypto.Blake2b`,
`Cometa.Encoding.Cbor`, the `Cometa.Crypto.Ed25519` modules, `Cometa.Error`, and
`Cometa.Error.Code`.
Use the same `--extra-include-dirs` and `--extra-lib-dirs` options as your build
when the native library is installed outside the default search paths.

## Availability

The library is unpublished, so there is no released online API reference yet.
Use the Haddock generated from the same source revision as your application.
A narrative guide build alone does not verify the Haskell package or its native
dependency.
