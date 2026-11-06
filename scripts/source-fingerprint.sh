#!/bin/sh
# Prints the source fingerprint that `amoo version` reports for a build of this checkout.
# Compare the two to tell whether a binary was built from the sources you are looking at,
# uncommitted ones included. The commit hash alone cannot, because a dirty build reports its base commit.
set -eu
repo=${1:-.}
cd "$repo"
files=$(
    git ls-files -co --exclude-standard -- Sources Protos Package.swift Package.resolved BuildPlugins scripts/build-provenance.sh |
        LC_ALL=C sort -u |
        while IFS= read -r path; do
            [ -f "$path" ] && printf '%s\n' "$path"
        done
)
{
    printf '%s\n' "$files"
    printf '%s\n' "$files" | git hash-object --no-filters --stdin-paths
} | git hash-object --stdin
