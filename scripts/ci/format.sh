#!/usr/bin/env bash
set -euo pipefail

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "error: swiftformat is not installed" >&2
  exit 1
fi

tmp_swift_file_list="$(mktemp)"
rg --files -g '*.swift' >"$tmp_swift_file_list" 2>/dev/null || true
swift_files_count=$(wc -l <"$tmp_swift_file_list" | tr -d ' ')
rm -f "$tmp_swift_file_list"
if [[ "$swift_files_count" -eq 0 ]]; then
  echo "No Swift files found. Skipping swiftformat."
  exit 0
fi

# SwiftFormat is not idempotent on this codebase (some rules only converge on a second pass),
# so run it twice — the second pass is a fast no-op when the first already reached a fixpoint.
swiftformat . --config .swiftformat --cache ignore
swiftformat . --config .swiftformat --cache ignore
