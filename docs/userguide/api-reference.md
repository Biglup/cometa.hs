# API reference

The [Haddock reference on Hackage](https://hackage.haskell.org/package/cometa-0.1.0.0/candidate/docs/index.html)
is the primary API documentation. It includes the Blockfrost provider and describes
arguments, units, bounds and errors for each operation. Version 0.1.0.0 is currently
a package candidate; it has not been published in the main package index.

## Build locally

To browse documentation matching your checkout:

```sh
python3 tools/build-api-docs.py
```

Open `docs/_build/api/index.html`. Configure the native dependency as for a normal
build first. `cabal haddock all` also generates local documentation.
