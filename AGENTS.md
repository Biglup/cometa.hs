# Repository instructions

Cometa.hs is an unpublished Haskell binding to cardano-c. Read
`CODING_CONVENTIONS.md` and `docs/development/IMPLEMENTATION_PLAN.md` before making
changes. Inspect neighboring modules, package metadata, native dependency pins,
and test provenance. The implementation plan contains proposed APIs; only code
and passing tests establish implemented behavior.

## Scope and workflow

- Make focused, reviewable changes. Do not generate broad FFI wrappers before
  auditing the native declarations, ownership contract, and public Haskell API.
- Keep implementation tracking in developer documents, not the user-facing README.
  Update the implementation plan when decisions, evidence, or milestones change.
- Do not advertise incomplete domains, untested platform/compiler combinations,
  unpublished packages, or unconfigured hosted documentation.
- Preserve the maintainer's configured signing identity. Use Conventional Commit
  messages when asked to commit; do not substitute an agent identity. Commit,
  publication, and live-network actions require the corresponding task authority.
- Never check in credentials, private keys, funded-wallet material, or secrets from
  conversation history. Live tests need explicit network, wallet, and flow authority.

## Haskell changes

- Follow `CODING_CONVENTIONS.md`, explicit exports, public signatures, and the
  configured formatter/HLint policy. Do not impose C/C++ formatting on Haskell.
- Use abstract validated values, structured errors, and qualified domain modules.
  Keep expected failure total and keep native effects in `IO`.
- Keep raw FFI, marshaling, resource scopes, and callbacks internal. Audit every
  acquired, borrowed, retained, and transferred native reference.
- Never hide arbitrary native calls with `unsafePerformIO`. Never derive printable
  secret representations or expose constructors that bypass invariants.
- Record every mapped C symbol, ownership rule, status, test, and justified omission
  in the API ledger as coverage expands. Reference-count plumbing is internal;
  domain functionality must not disappear under that label.

## Verification

Run checks appropriate to the change with the repository's native configuration:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock all
cabal check
```

Run the configured formatter and HLint checks for Haskell edits. Build narrative
changes with:

```sh
python3 -m sphinx -n -W --keep-going -b html docs/userguide docs/_build/html
```

- Add meaningful invalid-input and boundary tests for new behavior. Test advertised
  laws with properties and lifecycle behavior with failure/cancellation cases.
- Reuse the pinned native corpus through public Haskell values; opaque CBOR
  forwarding alone does not establish correct marshaling. Record source revision,
  path, and license/notices for imported vectors, properties, and generators.
- Compile documentation examples when adding executable examples. Pure doctests
  may use deterministic inputs; effectful examples must not require live secrets
  in ordinary CI.
- Review CI results before claiming a supported matrix or completed milestone.
  Report checks that could not run and the concrete reason.

## Documentation

Write public contracts in Haddock: meaning, units, bounds, ordering, defaults,
errors, and observable effects. Put ownership/runtime mechanics in internal docs.
Keep task-oriented prose in the Sphinx MyST guide; publish release API reference
through Haddock on Hackage. Do not create dead release links or status badges.
