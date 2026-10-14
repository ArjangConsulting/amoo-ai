#!/usr/bin/env bash
# Usage: ./scripts/ci/generate-release-notes.sh <version> [--highlights <file>] [--repo owner/name]
#        [--output <file>]
# Example: ./scripts/ci/generate-release-notes.sh 0.2.1
#
# Renders the GitHub release body for <version> from git history.
#
# amoo is trunk-based: changes land on `main` directly, so GitHub's PR-based
# `generate_release_notes` produces a body with nothing but a compare link. This script
# instead lists the commits themselves, grouped by conventional-commit type, each with a
# one-line explanation (the commit subject) and a link, plus a compare link against the
# previous tag — the same shape as an auto-generated changelog, but populated.
#
# An optional hand-written highlights block (--highlights <file>, or a `workflow_dispatch`
# input rendered to a file by release.yml) is prepended under "## Highlights". This is how
# maintainers add editorial context without a checked-in CHANGELOG.
#
# Notes live in GitHub Releases, not in the repo (see the project's global preferences).

set -euo pipefail

VERSION=""
HIGHLIGHTS_FILE=""
REPO="${GITHUB_REPOSITORY:-ArjangConsulting/amoo-ai}"
OUTPUT_FILE=""

usage() {
  cat >&2 <<'EOF'
Usage: generate-release-notes.sh <version> [options]

Arguments:
  <version>              Bare SemVer tag to render notes for (e.g. 0.2.1).

Options:
  --highlights <file>    Markdown file prepended under "## Highlights".
  --repo <owner/name>    Repository slug for links (default: $GITHUB_REPOSITORY).
  --output <file>        Write the body to <file> instead of stdout.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --highlights)
      HIGHLIGHTS_FILE="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$VERSION" ]]; then
        VERSION="$1"
      else
        echo "error: unexpected argument '$1'" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "error: missing <version>" >&2
  usage
  exit 1
fi

if [[ -z "$REPO" ]]; then
  echo "error: repository slug is empty (set GITHUB_REPOSITORY or pass --repo owner/name)" >&2
  exit 1
fi

# Bare SemVer only; strip a leading `v` defensively so a mis-typed tag still resolves.
VERSION="${VERSION#v}"

# release.yml renders these notes before it creates the tag, so a run that cuts a brand-new version
# has no tag yet — render the checked-out commit instead. Interactively a missing tag is almost
# always a forgotten `git fetch --tags`, so keep failing loudly there.
if git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then
  TARGET="${VERSION}"
elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "note: tag '${VERSION}' does not exist yet; rendering notes for HEAD." >&2
  TARGET="HEAD"
else
  echo "error: tag '${VERSION}' not found. Fetch tags (git fetch --tags) or check the version." >&2
  exit 1
fi

# Most recent bare-SemVer tag reachable from the release commit, excluding VERSION itself.
PREV_TAG="$(git tag --merged "${TARGET}" --sort=-v:refname --list '[0-9]*.[0-9]*.[0-9]*' |
  grep -vx "${VERSION}" | head -n1 || true)"

if [[ -n "$PREV_TAG" ]]; then
  RANGE="${PREV_TAG}..${TARGET}"
  COMPARE_URL="https://github.com/${REPO}/compare/${PREV_TAG}...${VERSION}"
else
  # First release on this history: list everything reachable from the release commit.
  RANGE="${TARGET}"
  COMPARE_URL="https://github.com/${REPO}/commits/${VERSION}"
fi

entries_feat=""
entries_fix=""
entries_perf=""
entries_refactor=""
entries_docs=""
entries_test=""
entries_meta=""
entries_other=""

while IFS=$'\t' read -r sha subject; do
  [[ -z "${sha:-}" ]] && continue
  short="${sha:0:7}"
  entry="- ${subject} ([${short}](https://github.com/${REPO}/commit/${sha}))"

  # Conventional-commit type: the token before '(' or ':' (e.g. "feat(mcp):" -> "feat").
  # Subjects without a recognizable type fall through to "Other Changes" below.
  type="${subject%%:*}"
  type="${type%!}"
  if [[ "$type" == *"("*")"* ]]; then
    type="${type%%(*}"
  fi

  case "$type" in
    feat) entries_feat+="${entry}"$'\n' ;;
    fix) entries_fix+="${entry}"$'\n' ;;
    perf) entries_perf+="${entry}"$'\n' ;;
    refactor | rename) entries_refactor+="${entry}"$'\n' ;;
    docs) entries_docs+="${entry}"$'\n' ;;
    test) entries_test+="${entry}"$'\n' ;;
    ci | build | chore) entries_meta+="${entry}"$'\n' ;;
    *) entries_other+="${entry}"$'\n' ;;
  esac
done < <(git log --no-merges --format='%H%x09%s' "${RANGE}")

section() {
  local title="$1" body="$2"
  if [[ -n "$body" ]]; then
    printf '### %s\n\n%s\n' "$title" "$body"
  fi
}

# Strip leading and trailing blank lines without relying on GNU-only sed.
trim_blank_lines() {
  awk 'NF { started = 1 } started { print }' |
    awk '{ line[NR] = $0 } END { end = 0; for (i = NR; i >= 1; i--) if (line[i] ~ /[^[:space:]]/) { end = i; break } for (i = 1; i <= end; i++) print line[i] }'
}

render() {
  if [[ -n "$HIGHLIGHTS_FILE" ]]; then
    if [[ ! -f "$HIGHLIGHTS_FILE" ]]; then
      echo "error: highlights file '${HIGHLIGHTS_FILE}' not found" >&2
      exit 1
    fi
    local highlights
    highlights="$(trim_blank_lines <"$HIGHLIGHTS_FILE")"
    if [[ -n "$highlights" ]]; then
      printf '## Highlights\n\n%s\n\n' "$highlights"
    fi
  fi

  printf '## What'"'"'s Changed\n\n'
  section "Features" "$entries_feat"
  section "Fixes" "$entries_fix"
  section "Performance" "$entries_perf"
  section "Refactoring" "$entries_refactor"
  section "Documentation" "$entries_docs"
  section "Tests" "$entries_test"
  section "Build, CI & Chores" "$entries_meta"
  section "Other Changes" "$entries_other"

  if [[ -z "$entries_feat$entries_fix$entries_perf$entries_refactor$entries_docs$entries_test$entries_meta$entries_other" ]]; then
    printf '_No changes recorded between `%s` and `%s`._\n\n' "${PREV_TAG:-the initial commit}" "${VERSION}"
  fi

  printf -- '---\n\n**Full Changelog**: %s\n' "$COMPARE_URL"
}

if [[ -n "$OUTPUT_FILE" ]]; then
  render >"$OUTPUT_FILE"
  echo "Wrote release notes for ${VERSION} to ${OUTPUT_FILE}" >&2
else
  render
fi
