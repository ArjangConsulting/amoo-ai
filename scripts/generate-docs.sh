#!/usr/bin/env bash
# Generates a single combined DocC site covering every documented library target.
#
# Usage:
#   scripts/generate-docs.sh [output-dir] [--static --hosting-base-path <path>]
#
# Examples:
#   scripts/generate-docs.sh                                   # local archive at .build/docs.doccarchive
#   scripts/generate-docs.sh site --static --hosting-base-path /amoo-ai   # GitHub Pages build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-.build/docs.doccarchive}"
shift || true

STATIC=0
HOSTING_BASE_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)
      STATIC=1
      shift
      ;;
    --hosting-base-path)
      HOSTING_BASE_PATH="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

TARGETS=(
  AmooCore
  CompanionProtocol
  IOSDriver
  AndroidDriver
  ProcessRunner
  GRPCService
  MCPServer
  AuditEngine
  CommandContract
  TestSession
  OllamaClient
)

export PROTOC_PATH="${PROTOC_PATH:-$(command -v protoc)}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVE_PATHS=()
for target in "${TARGETS[@]}"; do
  echo "Generating documentation for $target..."
  archive_path="$WORK_DIR/$target.doccarchive"
  swift package --allow-writing-to-directory "$WORK_DIR" \
    generate-documentation \
    --target "$target" \
    --output-path "$archive_path"
  ARCHIVE_PATHS+=("$archive_path")
done

MERGED_DIR="$WORK_DIR/merged.doccarchive"
echo "Merging ${#TARGETS[@]} archives into a combined site..."
xcrun docc merge "${ARCHIVE_PATHS[@]}" \
  --synthesized-landing-page-name "Amoo" \
  --output-path "$MERGED_DIR"

rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OUT_DIR")"

if [[ "$STATIC" -eq 1 ]]; then
  if [[ -z "$HOSTING_BASE_PATH" ]]; then
    echo "--static requires --hosting-base-path" >&2
    exit 1
  fi
  echo "Transforming merged archive for static hosting at $HOSTING_BASE_PATH..."
  xcrun docc process-archive transform-for-static-hosting "$MERGED_DIR" \
    --hosting-base-path "$HOSTING_BASE_PATH" \
    --output-path "$OUT_DIR"

  cat > "$OUT_DIR/index.html" <<EOF
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=documentation">
    <link rel="canonical" href="documentation">
    <title>Amoo Documentation</title>
  </head>
  <body>
    <p>Redirecting to <a href="documentation">Amoo documentation</a>...</p>
  </body>
</html>
EOF
else
  mv "$MERGED_DIR" "$OUT_DIR"
fi

echo "Documentation written to $OUT_DIR"
