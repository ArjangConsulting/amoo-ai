#!/usr/bin/env bash
# Usage: ./scripts/update-formula.sh <version>
# Example: ./scripts/update-formula.sh 0.2.0
#
# Downloads the macOS and Linux release tarballs for the given version, computes their
# SHA256 digests, and renders Formula/amoo.rb into ./rendered-amoo.rb — Formula/amoo.rb
# itself is a template checked into this repo (placeholders only) and must never be
# hand-edited or overwritten in place.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>  (e.g. 0.2.0)" >&2
  exit 1
fi

REPO="ArjangConsulting/amoo-ai"
BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
MACOS_TARBALL="amoo-${VERSION}-macos-universal.tar.gz"
LINUX_TARBALL="amoo-${VERSION}-linux-static.tar.gz"
FORMULA="Formula/amoo.rb"
RENDERED="rendered-amoo.rb"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading release assets for ${VERSION}..."
curl -fsSL --output "${TMPDIR}/${MACOS_TARBALL}" "${BASE_URL}/${MACOS_TARBALL}"
curl -fsSL --output "${TMPDIR}/${LINUX_TARBALL}" "${BASE_URL}/${LINUX_TARBALL}"

echo "Computing SHA256..."
if command -v sha256sum &>/dev/null; then
  MACOS_SHA256="$(sha256sum "${TMPDIR}/${MACOS_TARBALL}" | awk '{print $1}')"
  LINUX_SHA256="$(sha256sum "${TMPDIR}/${LINUX_TARBALL}" | awk '{print $1}')"
else
  MACOS_SHA256="$(shasum -a 256 "${TMPDIR}/${MACOS_TARBALL}" | awk '{print $1}')"
  LINUX_SHA256="$(shasum -a 256 "${TMPDIR}/${LINUX_TARBALL}" | awk '{print $1}')"
fi

echo "  macOS: ${MACOS_SHA256}"
echo "  Linux: ${LINUX_SHA256}"

echo "Rendering ${FORMULA} -> ${RENDERED}..."

sed -e "s/VERSION_PLACEHOLDER/${VERSION}/g" \
    -e "s/MACOS_SHA256_PLACEHOLDER/${MACOS_SHA256}/g" \
    -e "s/LINUX_SHA256_PLACEHOLDER/${LINUX_SHA256}/g" \
    "${FORMULA}" | tail -n +5 >"${RENDERED}"

echo "Done. ${RENDERED} written for ${VERSION}."
echo ""
echo "Copy it into the tap:"
echo "  cp ${RENDERED} ../homebrew-tap/Formula/amoo.rb"
