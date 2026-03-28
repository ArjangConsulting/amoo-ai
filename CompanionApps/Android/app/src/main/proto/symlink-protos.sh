#!/usr/bin/env bash
# Copy proto files from the shared Protos/ directory into the Android proto source set.
# Gradle's protobuf plugin expects protos in src/main/proto/.
#
# Run from the Android project root:
#   ./app/src/main/proto/symlink-protos.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_DIR="$SCRIPT_DIR/../../../../../../Protos"

for proto in common.proto actions.proto accessibility.proto ai.proto device.proto; do
    # Remove old symlink if present, then copy
    rm -f "$SCRIPT_DIR/$proto"
    cp "$PROTO_DIR/$proto" "$SCRIPT_DIR/$proto"
done

echo "Proto files copied to $SCRIPT_DIR"
