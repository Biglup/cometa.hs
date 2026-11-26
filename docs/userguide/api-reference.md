# API reference

The [Haddock reference on Hackage](https://hackage.haskell.org/package/cometa-0.2.0.0/docs/index.html)
is the primary API documentation. It includes the Blockfrost, Koios, Kupmios and Hydra providers and describes
arguments, units, bounds and errors for each operation. The linked reference
matches the published 0.2.0.0 package.

## Build locally

To browse documentation matching your checkout:

```sh
python3 tools/build-api-docs.py
```

Open `docs/_build/api/index.html`. Configure the native dependency as for a normal
build first. `cabal haddock all` also generates local documentation.
