#!/usr/bin/env bash
set -euo pipefail

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "error: swiftformat is not installed" >&2
  exit 1
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: swiftlint is not installed" >&2
  exit 1
fi

tmp_swift_file_list="$(mktemp)"
rg --files -g '*.swift' >"$tmp_swift_file_list" 2>/dev/null || true
swift_files_count=$(wc -l <"$tmp_swift_file_list" | tr -d ' ')
rm -f "$tmp_swift_file_list"
if [[ "$swift_files_count" -eq 0 ]]; then
  echo "No Swift files found. Skipping swiftformat/swiftlint."
  exit 0
fi

echo "Running swiftformat lint..."
swiftformat --lint . --config .swiftformat --cache ignore

echo "Running swiftlint..."
swiftlint lint --strict --no-cache
