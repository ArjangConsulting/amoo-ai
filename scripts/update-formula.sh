#!/usr/bin/env bash
# Usage: ./scripts/update-formula.sh <version>
# Example: ./scripts/update-formula.sh 0.2.0
#
# Downloads the macOS and Linux release tarballs for the given version,
# computes their SHA256 digests, and patches Formula/amoo.rb in place.

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

echo "Patching ${FORMULA}..."

sed -i.bak "s/^  version \".*\"/  version \"${VERSION}\"/" "${FORMULA}"
sed -i.bak "s/sha256 \"MACOS_SHA256_PLACEHOLDER\"/sha256 \"${MACOS_SHA256}\"/" "${FORMULA}"
sed -i.bak "s/sha256 \"LINUX_SHA256_PLACEHOLDER\"/sha256 \"${LINUX_SHA256}\"/" "${FORMULA}"

rm -f "${FORMULA}.bak"

echo "Done. ${FORMULA} updated for ${VERSION}."
echo ""
echo "Verify with:"
echo "  grep -E 'version|sha256|url' ${FORMULA}"
