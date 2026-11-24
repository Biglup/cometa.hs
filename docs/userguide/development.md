# Development

Follow `CODING_CONVENTIONS.md`. Configure the pinned native dependency using the
installation guide, then run:

```sh
cabal build all --ghc-options=-Werror
cabal test all --test-show-details=direct
cabal haddock all
cabal check
python3 -m unittest discover -s test/release -v
```

Use Ormolu 0.8.0.2 and HLint 3.8 with the repository configuration. Examples under
`examples/` are built by Cabal. Their shared support modules are exercised by the
offline workflow tests; fixture providers belong under `test/`.

## Native boundaries

Keep raw FFI declarations, marshaling and reference management internal. Preserve
exact integers, meaningful collection order, and original encodings where they
affect transaction identity. Public operations return structured domain errors.
Add boundary tests for validation and cancellation/failure tests for ownership.
Preserve test-vector licenses and provenance under `test/Fixtures`.

The BIP39 and PBKDF2 purity audits under `docs/development/` document the narrow
exceptions to effectful native calls. Revisit those audits when changing their
native dependency paths. Release and benchmark instructions are kept there too.

## Documentation

Public contracts live in Haddock and are uploaded to Hackage with the package.
The small Sphinx guide covers workflows without duplicating the API reference.
Read the Docs builds the guide from `main` using `.readthedocs.yaml`.

```sh
python3 -m pip install -r docs/requirements.txt
python3 -m sphinx -n -W --keep-going -b html docs/userguide docs/_build/html
```
