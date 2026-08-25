# Homebrew Release Checklist

> Maintainer-only release checklist. Not mirrored in DocC.

Use this checklist when publishing `amoo` to the Homebrew tap.

## Prerequisites

- `ArjangConsulting/amoo-ai` is public.
- The tap repository `ArjangConsulting/homebrew-tap` exists.
- The release tag exists in this repository.

## Pre-Tag Validation

Run the release build and blocking test suite before tagging:

```bash
./scripts/with-protoc.sh swift build -c release
./scripts/ci/test_coverage.sh
.build/release/amoo --help
```

The checked-in development version is not the pending tag: the release workflow stamps the tag
into `CLIApp.versionString` in its isolated checkout, then asserts both packaged binaries report
that exact version before publishing them.

## Tag the Release

amoo uses plain semantic-version tags, not `v`-prefixed tags:

```bash
git tag <version>
git push origin <version>
```

## Tap Update Is Automated

The tap formula points at the **prebuilt binary tarballs** attached to each GitHub Release
(`amoo-<version>-macos-universal.tar.gz` and `amoo-<version>-linux-static.tar.gz`), not a source
tarball. The release workflow updates the tap automatically:

1. After the macOS + Linux binaries are built and the GitHub Release is created, the
   `Update Homebrew tap` step computes each tarball's SHA256.
2. It renders `Formula/amoo.rb` (this repo's template), substituting the version and both SHA256
   values. The download URLs use the **bare** tag (no `v` prefix), matching the release.
3. It commits the rendered formula to `ArjangConsulting/homebrew-tap` (`Formula/amoo.rb`).

This requires a repository secret **`HOMEBREW_TAP_TOKEN`** — a fine-grained PAT (or classic token)
with `contents: write` on `ArjangConsulting/homebrew-tap`. If the secret is absent the step logs a
notice and skips; complete the [manual fallback](#manual-fallback) below.

### Manual Fallback

If the automated step was skipped, render and publish the formula by hand from this repo, using
the SHA256 of the **release binary** tarballs (not a source tarball):

```bash
./scripts/update-formula.sh <version>
cp rendered-amoo.rb ../homebrew-tap/Formula/amoo.rb
```

or compute it directly:

```bash
VERSION=<version>
gh release download "$VERSION" -p 'amoo-*-macos-universal.tar.gz' -p 'amoo-*-linux-static.tar.gz'
macos_sha=$(shasum -a 256 "amoo-${VERSION}-macos-universal.tar.gz" | awk '{print $1}')
linux_sha=$(shasum -a 256 "amoo-${VERSION}-linux-static.tar.gz" | awk '{print $1}')
sed -e "s/VERSION_PLACEHOLDER/${VERSION}/g" \
    -e "s/MACOS_SHA256_PLACEHOLDER/${macos_sha}/g" \
    -e "s/LINUX_SHA256_PLACEHOLDER/${linux_sha}/g" \
    Formula/amoo.rb > ../homebrew-tap/Formula/amoo.rb
```

## Validate the Formula Locally

Homebrew 5.1+ requires the formula to live in a tap. For local testing, create or update a tap and
copy the formula into it:

```bash
brew tap-new arjangconsulting/tap
TAP_DIR="$(brew --repository)/Library/Taps/arjangconsulting/homebrew-tap"
mkdir -p "$TAP_DIR/Formula"
cp ../homebrew-tap/Formula/amoo.rb "$TAP_DIR/Formula/amoo.rb"
brew uninstall --force amoo || true
brew install arjangconsulting/tap/amoo
brew test arjangconsulting/tap/amoo
amoo --version
```

## Publish the Tap Update

Commit and push the formula change in `ArjangConsulting/homebrew-tap`, then users can install
with:

```bash
brew tap arjangconsulting/tap
brew install amoo
```
