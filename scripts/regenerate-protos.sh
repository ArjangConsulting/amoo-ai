#!/usr/bin/env bash
# Regenerate the committed host-side protobuf/gRPC Swift in Sources/Protos/Generated from Protos/*.proto.
#
# Normal builds do not run the GRPCProtobufGenerator plugin (it makes SwiftPM compile protoc from
# C++ source, 3-6 min per clean build — see the note at the top of Package.swift). Setting
# AMOO_REGENERATE_PROTOS=1 adds a ProtosGenerator target that does run it; this script builds that
# target and copies the plugin output over the committed files.
#
#   scripts/regenerate-protos.sh          # rewrite Sources/Protos/Generated
#   scripts/regenerate-protos.sh --check  # fail if the committed files are stale (CI)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/Sources/Protos/Generated"
CHECK=false

case "${1:-}" in
    "") ;;
    --check) CHECK=true ;;
    *)
        echo "usage: scripts/regenerate-protos.sh [--check]" >&2
        exit 64
        ;;
esac

cd "$REPO_ROOT"

# Remove only this package's plugin output so a rename of the checkout directory (or a deleted
# .proto) can never leak stale files into the copy below.
OUTPUTS="$REPO_ROOT/.build/plugins/outputs"
if [[ -d "$OUTPUTS" ]]; then
    find "$OUTPUTS" -type d -path '*/ProtosGenerator/destination/GRPCProtobufGenerator' -exec rm -rf {} + 2>/dev/null || true
fi

AMOO_REGENERATE_PROTOS=1 "$REPO_ROOT/scripts/with-protoc.sh" swift build --target ProtosGenerator

GENERATED=()
while IFS= read -r dir; do
    GENERATED+=("$dir")
done < <(find "$OUTPUTS" -type d -path '*/ProtosGenerator/destination/GRPCProtobufGenerator')
if [[ "${#GENERATED[@]}" -ne 1 ]]; then
    echo "error: expected exactly one ProtosGenerator plugin output directory, found ${#GENERATED[@]}." >&2
    exit 1
fi

mkdir -p "$DEST"
rm -f "$DEST"/*.swift
cp "${GENERATED[0]}"/*.swift "$DEST"/

if [[ "$CHECK" == true ]]; then
    if [[ -n "$(git status --porcelain -- Sources/Protos/Generated)" ]]; then
        echo "error: Sources/Protos/Generated is stale relative to Protos/*.proto. Run 'make protos' and commit." >&2
        git --no-pager diff --stat -- Sources/Protos/Generated >&2 || true
        exit 1
    fi
    echo "Sources/Protos/Generated is up to date."
else
    echo "Regenerated $(find "$DEST" -name '*.swift' | wc -l | tr -d ' ') files in Sources/Protos/Generated."
fi
