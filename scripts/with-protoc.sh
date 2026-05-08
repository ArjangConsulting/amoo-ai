#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: scripts/with-protoc.sh <command> [args...]" >&2
  exit 64
fi

if [[ -z "${PROTOC_PATH:-}" ]]; then
  if command -v protoc >/dev/null 2>&1; then
    PROTOC_PATH="$(command -v protoc)"
  elif command -v brew >/dev/null 2>&1; then
    echo "protoc not found. Installing protobuf with Homebrew..." >&2
    brew install protobuf
    PROTOC_PATH="$(brew --prefix protobuf)/bin/protoc"
  else
    echo "error: protoc is required for protobuf code generation." >&2
    echo "Install protobuf or set PROTOC_PATH to a protoc executable." >&2
    exit 1
  fi
fi

if [[ ! -x "$PROTOC_PATH" ]]; then
  echo "error: PROTOC_PATH does not point to an executable: $PROTOC_PATH" >&2
  exit 1
fi

export PROTOC_PATH
exec "$@"
