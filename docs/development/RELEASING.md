# Releasing Cometa

The `Release` workflow is manual. It does not publish on a pull request, a push,
or a tag push. Its `validate` job runs the complete reusable CI workflow at the
selected commit: Linux x64/ARM64, macOS Intel/ARM64, Windows, the additional GHC
9.10 build, installed-library compatibility, lint, documentation and Valgrind.
Every validation job must pass before release preparation or upload. Merge the
workflow into the default branch before its first manual invocation.

## Credentials

Create a Hackage account with uploader permission and maintainership of the
packages being updated. Store its API token as `HACKAGE_TOKEN` in the repository's
GitHub environment named `release`. Only the upload step receives that token.
The workflow uses the normal GitHub token for attaching release assets.

## Prepare a candidate

Update `cometa.cabal`, the changelog, and the native package metadata when needed.
`native/package.json` controls the native package version; Cometa must depend on
that exact version. A change to the bundled native payload requires a new native
package version. Keep `native/cardano-c.ref` synchronized with the intended source.

Open **Actions → Release → Run workflow**, select the branch to test, and
leave `mode` set to `candidate`. The workflow:

1. Runs the full platform matrix and repository checks.
2. Generates both source packages and validates an independent consumer of them.
3. Builds one API documentation archive, including the Blockfrost provider.
4. Records the source revision, native revision, archive hashes and versions.
5. Uploads the native candidate first, then Cometa and its documentation.

Download `release-packages` from the workflow to inspect the exact archives and
`SHA256SUMS`. Candidate uploads are outside the normal Hackage index; validation
uses both archives explicitly. An identical native version already published on
Hackage can be reused. Both packages are source distributions, not precompiled
Haskell binaries. Blockfrost is included in the main `cometa` library.

## Publish

Create and push a signed `vVERSION` tag at the intended release commit, with
`VERSION` matching `cometa.cabal`. Dispatch the workflow at that tag with GitHub
CLI (replace `VERSION`):

```sh
gh workflow run release.yml --repo Biglup/cometa.hs --ref vVERSION -f mode=publish -f github_prerelease=true
```

Set `github_prerelease=false` for a regular GitHub release. Publishing from a
branch or a mismatched version tag is rejected.

The full validation and artifact preparation run again. The upload job consumes
the prepared artifacts without rebuilding them. It publishes `cardano-c-clib`
before `cometa`, then uploads the API documentation. After a fresh consumer
resolves the exact Cometa version through Hackage, the workflow creates or updates
the GitHub release and attaches the same archives, manifest and checksums.

Published source versions cannot be replaced. On a retry, an existing source
version is skipped only when its archive hash matches exactly; a mismatch stops
the release. Both source versions are checked before either is uploaded.
Documentation can be uploaded again. If verification fails after publication,
the uploaded packages remain published; diagnose the failure and retry the same
tag rather than attempting to replace a source version.

The Read the Docs guide retains its existing deployment. Hackage hosts the
versioned Haddock API reference.

## Local checks

These commands prepare and validate artifacts without uploading:

```sh
python3 tools/package-native.py /path/to/pinned/cardano-c
cabal sdist all --output-directory=release-artifacts
python3 tools/check-source-package.py release-artifacts/cometa-*.tar.gz --native-archive release-artifacts/cardano-c-clib-*.tar.gz
python3 tools/build-api-docs.py --hackage
cp dist-newstyle/cometa-*-docs.tar.gz release-artifacts/
GITHUB_SHA="$(git rev-parse HEAD)" python3 tools/release.py prepare --mode candidate
python3 -m unittest discover -s test/release -v
```

After publication, `python3 tools/check-source-package.py --published-version
VERSION` updates the package index and builds the public consumer without local
source archives or native library paths.
