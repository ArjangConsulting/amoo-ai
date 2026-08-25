#!/usr/bin/env bash
# Verify the Linux build of amoo inside the official Swift container.
#
# Mirrors the Linux job in .github/workflows/ci.yml: install protoc, build the
# `amoo` product, then run the unit test suite. CLIQualityCoverageTests is skipped because its
# Android preflight checks scan the real host for a JDK rather than going through the injected
# process runner — a host tooling gap on a bare container, not a Linux-compatibility issue.
#
# Usage:
#   scripts/verify-linux.sh                # build + test run
#   scripts/verify-linux.sh build          # build only
#   scripts/verify-linux.sh shell          # interactive shell in the container
#   scripts/verify-linux.sh --image swift:6.3-noble <subcommand>

set -euo pipefail

IMAGE="swift:6.3-noble"
SUBCOMMAND="ci"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    build|test|ci|shell) SUBCOMMAND="$1"; shift ;;
    -h|--help)
      sed -n '1,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="/workspace"

install_protoc() {
  echo "apt-get update -qq && apt-get install -y -qq protobuf-compiler >/dev/null && export PROTOC_PATH=\$(which protoc) &&"
}

run_in_container() {
  docker run --rm -i \
    -v "${REPO_ROOT}":${WORKDIR} \
    -v amoo-linux-spm-cache:/root/.swiftpm \
    -w ${WORKDIR} \
    "${IMAGE}" \
    bash -lc "$(install_protoc) $1"
}

case "${SUBCOMMAND}" in
  build)
    run_in_container "swift --version && swift build --build-path .build-linux --product amoo"
    ;;
  test)
    run_in_container "swift --version && swift test --build-path .build-linux --skip IntegrationTests --skip CLIQualityCoverageTests"
    ;;
  ci)
    run_in_container "swift --version && swift build --build-path .build-linux --product amoo && swift test --build-path .build-linux --skip IntegrationTests --skip CLIQualityCoverageTests"
    ;;
  shell)
    docker run --rm -it \
      -v "${REPO_ROOT}":${WORKDIR} \
      -v amoo-linux-spm-cache:/root/.swiftpm \
      -w ${WORKDIR} \
      "${IMAGE}" \
      bash
    ;;
esac
