#!/usr/bin/env bash
set -euo pipefail

ROOT_MIN=${ROOT_COVERAGE_MIN:-80}
CORE_MIN=${CORE_COVERAGE_MIN:-85}
DRIVER_MIN=${DRIVER_COVERAGE_MIN:-75}

WORKSPACE_HOME="${PWD}/.ci-home"
WORKSPACE_CLANG_CACHE="${PWD}/.build/clang-module-cache"
WORKSPACE_SWIFT_CACHE="${PWD}/.build/swift-module-cache"

mkdir -p "$WORKSPACE_HOME" "$WORKSPACE_CLANG_CACHE" "$WORKSPACE_SWIFT_CACHE"

if [[ -z "${PROTOC_PATH:-}" ]]; then
  if command -v protoc >/dev/null 2>&1; then
    PROTOC_PATH="$(command -v protoc)"
  elif command -v brew >/dev/null 2>&1 && [[ -x "$(brew --prefix protobuf 2>/dev/null)/bin/protoc" ]]; then
    PROTOC_PATH="$(brew --prefix protobuf)/bin/protoc"
  else
    echo "error: protoc is not installed or PROTOC_PATH is not set" >&2
    exit 1
  fi
fi

export PROTOC_PATH

PROFILE_BASE_DIR="${TMPDIR:-/tmp}"
PROFILE_BASE_DIR="${PROFILE_BASE_DIR%/}"
LLVM_PROFILE_FILE="${LLVM_PROFILE_FILE:-$PROFILE_BASE_DIR/mobile-testing-%p.profraw}"
export LLVM_PROFILE_FILE

if [[ ! -f Package.swift ]]; then
  echo "No Package.swift found. Skipping tests and coverage gate for now."
  exit 0
fi

echo "Running tests with code coverage enabled..."
HOME="$WORKSPACE_HOME" \
CLANG_MODULE_CACHE_PATH="$WORKSPACE_CLANG_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$WORKSPACE_SWIFT_CACHE" \
swift test --enable-code-coverage

CODECOV_PATH=$(
  HOME="$WORKSPACE_HOME" \
  CLANG_MODULE_CACHE_PATH="$WORKSPACE_CLANG_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$WORKSPACE_SWIFT_CACHE" \
  swift test --show-codecov-path
)
if [[ ! -f "$CODECOV_PATH" ]]; then
  echo "error: coverage JSON not found at $CODECOV_PATH" >&2
  exit 1
fi

python - "$CODECOV_PATH" "$ROOT_MIN" "$CORE_MIN" "$DRIVER_MIN" <<'PY'
import json
import sys
from pathlib import Path

codecov_path = Path(sys.argv[1])
root_min = float(sys.argv[2])
core_min = float(sys.argv[3])
driver_min = float(sys.argv[4])
repo_root = str(Path.cwd())

with codecov_path.open() as f:
    report = json.load(f)

data = report["data"][0]
files = data.get("files", [])


def aggregate(prefixes: list[str]):
    total_count = 0.0
    total_covered = 0.0
    for entry in files:
        filename = entry.get("filename", "")
        if any(p in filename for p in prefixes):
            lines = entry.get("summary", {}).get("lines", {})
            count = float(lines.get("count", 0.0))
            covered = float(lines.get("covered", 0.0))
            total_count += count
            total_covered += covered
    if total_count == 0:
        return None
    return (total_covered / total_count) * 100.0

root_cov = aggregate([f"{repo_root}/Sources/"])
core_cov = aggregate(["/Sources/MobileTestingCore/"])
driver_cov = aggregate([
    "/Sources/IOSDriver/",
    "/Sources/AndroidDriver/",
    "/Sources/CompanionProtocol/",
    "/Sources/ProcessRunner/",
    "/Sources/GRPCService/",
    "/Sources/MCPServer/",
])

if root_cov is None:
    root_cov = 0.0

print(f"Repo coverage: {root_cov:.2f}% (min {root_min:.2f}%)")
if core_cov is None:
    print("MobileTestingCore coverage: N/A (module not present yet)")
else:
    print(f"MobileTestingCore coverage: {core_cov:.2f}% (min {core_min:.2f}%)")

if driver_cov is None:
    print("Driver/protocol coverage: N/A (modules not present yet)")
else:
    print(f"Driver/protocol coverage: {driver_cov:.2f}% (min {driver_min:.2f}%)")

failures = []
if root_cov < root_min:
    failures.append(f"Repo coverage {root_cov:.2f}% is below {root_min:.2f}%")
if core_cov is not None and core_cov < core_min:
    failures.append(f"MobileTestingCore coverage {core_cov:.2f}% is below {core_min:.2f}%")
if driver_cov is not None and driver_cov < driver_min:
    failures.append(f"Driver/protocol coverage {driver_cov:.2f}% is below {driver_min:.2f}%")

if failures:
    print("\nCoverage gate failed:")
    for item in failures:
        print(f"- {item}")
    sys.exit(1)

print("Coverage gate passed.")
PY
