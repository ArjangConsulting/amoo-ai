#!/usr/bin/env bash
# Generate Swift protobuf + gRPC v2 stubs for the iOS companion app.
#
# Prerequisites:
#   brew install swift-protobuf protoc-gen-grpc-swift
#
# Uses protoc-gen-grpc-swift-2 for grpc-swift v2 compatible stubs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_DIR="$SCRIPT_DIR/../../Protos"
OUTPUT_DIR="$SCRIPT_DIR/GeneratedProtos"

mkdir -p "$OUTPUT_DIR"

# Use the Homebrew-installed protoc (may differ from conda)
PROTOC="${PROTOC:-$(brew --prefix)/bin/protoc}"
if [ ! -x "$PROTOC" ]; then
    PROTOC="$(which protoc)"
fi

PROTOS=(
    common.proto
    actions.proto
    accessibility.proto
    ai.proto
    device.proto
)

echo "Using protoc: $PROTOC"
echo "Proto dir: $PROTO_DIR"
echo "Output dir: $OUTPUT_DIR"

echo ""
echo "Generating Swift protobuf message stubs..."
for proto in "${PROTOS[@]}"; do
    echo "  $proto"
    "$PROTOC" \
        --proto_path="$PROTO_DIR" \
        --swift_out="$OUTPUT_DIR" \
        --swift_opt=Visibility=Public \
        "$PROTO_DIR/$proto"
done

echo ""
echo "Generating Swift gRPC v2 stubs..."
for proto in "${PROTOS[@]}"; do
    echo "  $proto"
    "$PROTOC" \
        --proto_path="$PROTO_DIR" \
        --plugin=protoc-gen-grpc-swift="$(which protoc-gen-grpc-swift-2)" \
        --grpc-swift_out="$OUTPUT_DIR" \
        --grpc-swift_opt=Visibility=Public \
        "$PROTO_DIR/$proto"
done

echo ""
echo "Generated files:"
ls "$OUTPUT_DIR"/*.swift 2>/dev/null || echo "  (none)"
