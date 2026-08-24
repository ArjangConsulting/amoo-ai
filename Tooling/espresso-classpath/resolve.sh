#!/bin/bash
# Resolves a real classpath (Espresso + AndroidX JUnit + Hamcrest + the Android platform stub jar)
# for compile-verifying generated Kotlin. Prints one line: a colon-separated classpath.
# Exits non-zero (with nothing on stdout) if any required tool/dependency is unavailable, so
# callers can treat that as "skip this verification" rather than a hard failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${TMPDIR:-/tmp}/amoo-espresso-classpath"
CACHE_FILE="$CACHE_DIR/classpath.txt"
EXTRACT_DIR="$CACHE_DIR/extracted"

command -v gradle >/dev/null 2>&1 || exit 1

ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_JAR=$(find "$ANDROID_SDK/platforms" -maxdepth 2 -name "android.jar" 2>/dev/null | sort -V | tail -1)
[ -n "$ANDROID_JAR" ] || exit 1

if [ -f "$CACHE_FILE" ] && [ "$CACHE_FILE" -nt "$SCRIPT_DIR/build.gradle.kts" ]; then
    cat "$CACHE_FILE"
    exit 0
fi

mkdir -p "$EXTRACT_DIR"

entries=$(cd "$SCRIPT_DIR" && gradle printClasspath -q | grep "^CLASSPATH_ENTRY:" | sed 's/CLASSPATH_ENTRY://')

jars=()
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if [[ "$entry" == *.aar ]]; then
        name=$(basename "$entry" .aar)
        dest="$EXTRACT_DIR/$name"
        mkdir -p "$dest"
        unzip -o -q "$entry" classes.jar -d "$dest" 2>/dev/null || true
        [ -f "$dest/classes.jar" ] && jars+=("$dest/classes.jar")
    else
        jars+=("$entry")
    fi
done <<<"$entries"

jars+=("$ANDROID_JAR")

classpath=$(IFS=:; echo "${jars[*]}")
echo "$classpath" > "$CACHE_FILE"
echo "$classpath"
