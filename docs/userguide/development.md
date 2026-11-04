# Development

Read the repository's `AGENTS.md`, `CODING_CONVENTIONS.md`, and
`docs/development/IMPLEMENTATION_PLAN.md` before extending the binding. The plan
contains proposals and acceptance gates; it is not a list of available APIs.

## Build and test

Configure the native dependency as described in [installation](installation.md),
then use:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock all
cabal check
```

Use Ormolu 0.8.0.2 and HLint 3.8 with the repository's HLint configuration.
New pure validation and conversion code needs boundary and invalid-input tests.
Native code also needs ownership and failure-path checks. Document the native revision and test-vector
provenance with the tests. Keep live network tests separate from deterministic
checks; executing funded transactions requires explicit authorization.

## Architecture

Public domain modules expose Haskell-owned values and explicit effects. Internal
FFI declarations, marshaling, and ownership management remain separate. Ordinary
users should not need raw pointers, reference counting, or callback registration.
Native operations remain in `IO`; expected domain errors use `Either`.

Preserve exact integers, collection ordering and duplicates where meaningful,
and original encodings where transaction identity depends on them. A future
transaction implementation must establish these contracts before claiming
serialization or signing support.

## Build the guide

The guide requires Python, but no GHC or native library:

```sh
python3 -m pip install -r docs/requirements.txt
python3 -m sphinx -n -W --keep-going -b html docs/userguide docs/_build/html
python3 -m sphinx -n -W --keep-going -b linkcheck docs/userguide docs/_build/linkcheck
```

Warnings fail the documentation build. Review the generated pages for navigation,
code blocks, and links. Link checking needs network access; report external
failures separately from a successful HTML build.

## Publishing

`.readthedocs.yaml` installs the pinned documentation dependencies and builds the
guide with warnings treated as errors. A maintainer must import the repository
into the Read the Docs project `cometahs` and enable the required versions.
Advertise the hosted link and status badge after its first successful build.

Generate Haddock in the Haskell build environment, where native headers and
libraries are available. Publish versioned Haddock with the Hackage package at
release, then update that release's guide to link to it. Do not generate a second
API reference from C headers or make the narrative site's build depend on native
compilation.
