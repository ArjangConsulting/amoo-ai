#!/usr/bin/env bash
# Prints a JAVA_HOME the Android companion's Gradle build can run on, or nothing.
#
# AGP 8.7 does not run on a JDK newer than 21. Past that, the Gradle daemon fails partway
# through with errors that name neither Java nor the JDK: `JdkImageTransform` failing to run
# `jlink` over core-for-system-modules.jar, or mergeDebugResources dying on a missing
# com/android/aaptcompiler/ResourceCompiler. Homebrew's `openjdk` is well past that range, so a
# machine with no explicit JAVA_HOME hits this by default.
#
# Mirrors Sources/CLI/AndroidJDK.swift, which does the same for `amoo companion`.
set -euo pipefail

MIN_VERSION=17
MAX_VERSION=21

major_version_of() {
  local release="$1/release"
  [ -r "$release" ] || return 1
  local raw
  raw="$(sed -n 's/^JAVA_VERSION="\{0,1\}\([0-9][0-9.]*\).*/\1/p' "$release" | head -1)"
  [ -n "$raw" ] || return 1
  local major="${raw%%.*}"
  # "1.8.0_402" for 8, "21.0.12" for everything modern.
  if [ "$major" = "1" ]; then
    raw="${raw#1.}"
    major="${raw%%.*}"
  fi
  echo "$major"
}

is_supported() {
  [ "$1" -ge "$MIN_VERSION" ] && [ "$1" -le "$MAX_VERSION" ]
}

# A JAVA_HOME already in range is a deliberate choice by the user or by CI — keep it.
if [ -n "${JAVA_HOME:-}" ] && version="$(major_version_of "$JAVA_HOME")" && is_supported "$version"; then
  echo "$JAVA_HOME"
  exit 0
fi

if [ -x /usr/libexec/java_home ]; then
  for candidate in $(seq "$MAX_VERSION" -1 "$MIN_VERSION"); do
    if home="$(/usr/libexec/java_home -v "$candidate" 2>/dev/null)"; then
      echo "$home"
      exit 0
    fi
  done
fi

# Newest supported wins, so a machine with both 17 and 21 builds on 21.
best_home=""
best_version=0
for root in /Library/Java/JavaVirtualMachines "$HOME/Library/Java/JavaVirtualMachines"; do
  [ -d "$root" ] || continue
  for jdk in "$root"/*/Contents/Home; do
    [ -d "$jdk" ] || continue
    version="$(major_version_of "$jdk")" || continue
    if is_supported "$version" && [ "$version" -gt "$best_version" ]; then
      best_home="$jdk"
      best_version="$version"
    fi
  done
done

[ -n "$best_home" ] && echo "$best_home"
exit 0
