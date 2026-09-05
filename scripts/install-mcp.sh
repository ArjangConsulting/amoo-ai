#!/usr/bin/env bash
# Registers amoo as an MCP server with a locally installed AI client (Claude Code, Claude
# Desktop, Codex, Cursor, or Windsurf). Opt-in only — this never runs automatically (not from
# `brew install`, not from `make`); the user invokes it by hand and confirms every write.
#
# Usage:
#   scripts/install-mcp.sh                    # detect installed clients, ask which to configure
#   scripts/install-mcp.sh --client claude-code
#   scripts/install-mcp.sh --client all --platform android
#   scripts/install-mcp.sh --dry-run           # show what would change, write nothing
#   scripts/install-mcp.sh --uninstall --client cursor
#
# See docs/mcp-server.md for the manual/copy-paste config equivalent of everything this does.
set -euo pipefail

PLATFORM="ios"
CLIENT="ask"
DRY_RUN=0
UNINSTALL=0
BIN_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/install-mcp.sh [--client claude-code|claude-desktop|codex|cursor|windsurf|all]
                               [--platform ios|android] [--bin /path/to/amoo]
                               [--dry-run] [--uninstall]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --client) CLIENT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --bin) BIN_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$PLATFORM" in
  ios|android) ;;
  *) echo "error: --platform must be 'ios' or 'android'" >&2; exit 1 ;;
esac

# Resolve the amoo binary. Prefers the Homebrew keg (works on both the Apple Silicon default
# prefix /opt/homebrew and the Intel default /usr/local — `brew --prefix` reports whichever is
# active rather than hardcoding either), then falls back to PATH, then a local release build.
resolve_bin() {
  if [ -n "$BIN_PATH" ]; then
    echo "$BIN_PATH"
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    if brew_prefix="$(brew --prefix amoo 2>/dev/null)" && [ -x "$brew_prefix/bin/amoo" ]; then
      echo "$brew_prefix/bin/amoo"
      return
    fi
  fi
  if command -v amoo >/dev/null 2>&1; then
    command -v amoo
    return
  fi
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -x "$repo_root/.build/release/amoo" ]; then
    echo "$repo_root/.build/release/amoo"
    return
  fi
  echo ""
}

AMOO_BIN="$(resolve_bin)"
if [ -z "$AMOO_BIN" ] && [ "$UNINSTALL" -eq 0 ]; then
  echo "error: could not find the amoo binary." >&2
  echo "Install it first (brew install amoo, or swift build -c release), or pass --bin." >&2
  exit 1
fi
[ -n "$AMOO_BIN" ] && echo "Using amoo binary: $AMOO_BIN"

PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ]; then
  echo "error: python3 is required (used for safe JSON config merges) and was not found." >&2
  exit 1
fi

confirm() {
  local prompt="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# json_merge_server <mode: preview|write> <config-file> <server-key> <command> <arg1> [arg2 ...]
# In "preview" mode, computes the before/after diff and prints it without touching disk. In
# "write" mode, applies the same merge (or removal, if UNINSTALL=1) atomically via a temp file.
# Never modifies any other content in the file. Creates parent dirs if needed.
json_merge_server() {
  local mode="$1" file="$2" key="$3"; shift 3
  mkdir -p "$(dirname "$file")"
  "$PYTHON" - "$mode" "$file" "$key" "$UNINSTALL" "$@" <<'PYEOF'
import json, os, sys

mode, file, key, uninstall = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
rest = sys.argv[5:]

data = {}
if os.path.exists(file):
    with open(file) as f:
        raw = f.read().strip()
    data = json.loads(raw) if raw else {}

servers = data.setdefault("mcpServers", {})
before = json.dumps(servers.get(key), sort_keys=True)

if uninstall:
    servers.pop(key, None)
else:
    servers[key] = {"command": rest[0], "args": rest[1:]}

after = json.dumps(servers.get(key), sort_keys=True)
if before == after:
    print("UNCHANGED")
    sys.exit(0)

print(f"--- {key} (before)\n{before}\n+++ {key} (after)\n{after}")
if mode == "write":
    with open(file + ".amoo-tmp", "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(file + ".amoo-tmp", file)
PYEOF
}

apply_json_client() {
  local name="$1" file="$2" key="$3"
  echo
  echo "== $name =="
  echo "config file: $file"
  local result
  result="$(json_merge_server preview "$file" "$key" "$AMOO_BIN" mcp serve --platform "$PLATFORM")"
  if [ "$result" = "UNCHANGED" ]; then
    echo "no change needed."
    return
  fi
  echo "$result"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry run — not written)"
    return
  fi
  if confirm "Apply this change to $file?"; then
    json_merge_server write "$file" "$key" "$AMOO_BIN" mcp serve --platform "$PLATFORM" >/dev/null
    echo "done."
  else
    echo "skipped."
  fi
}

install_claude_code() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "Claude Code CLI not found on PATH, skipping."
    return
  fi
  echo
  echo "== Claude Code =="
  if [ "$UNINSTALL" -eq 1 ]; then
    echo "Would run: claude mcp remove amoo"
    if [ "$DRY_RUN" -eq 0 ] && confirm "Remove the amoo MCP server from Claude Code?"; then
      claude mcp remove amoo || true
    fi
    return
  fi
  echo "Would run: claude mcp add amoo -- $AMOO_BIN mcp serve --platform $PLATFORM"
  if [ "$DRY_RUN" -eq 0 ] && confirm "Register amoo with Claude Code now?"; then
    claude mcp add amoo -- "$AMOO_BIN" mcp serve --platform "$PLATFORM"
  fi
}

install_claude_desktop() {
  local file="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  if [ ! -d "$HOME/Library/Application Support/Claude" ]; then
    echo "Claude Desktop not found (no ~/Library/Application Support/Claude), skipping."
    return
  fi
  apply_json_client "Claude Desktop" "$file" "amoo"
}

install_codex() {
  if ! command -v codex >/dev/null 2>&1 && [ ! -d "$HOME/.codex" ]; then
    echo "Codex CLI not found, skipping."
    return
  fi
  local file="$HOME/.codex/config.toml"
  echo
  echo "== Codex =="
  echo "config file: $file (TOML — merged by hand, not via json_merge_server)"
  local block
  block="$(cat <<EOF
[mcp_servers.amoo]
command = "$AMOO_BIN"
args = ["mcp", "serve", "--platform", "$PLATFORM"]
EOF
)"
  if [ "$UNINSTALL" -eq 1 ]; then
    if [ -f "$file" ] && grep -q '^\[mcp_servers\.amoo\]' "$file"; then
      echo "Found an [mcp_servers.amoo] block in $file."
      if confirm "Remove it? (opens \$EDITOR-free manual removal is safer for TOML; this does a line-range delete)"; then
        "$PYTHON" - "$file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = re.sub(r"\n?\[mcp_servers\.amoo\]\n(?:[^\[\n][^\n]*\n?)*", "\n", text)
with open(path, "w") as f:
    f.write(text)
PYEOF
        echo "removed."
      fi
    else
      echo "no amoo entry found."
    fi
    return
  fi
  if [ -f "$file" ] && grep -q '^\[mcp_servers\.amoo\]' "$file"; then
    echo "$file already has an [mcp_servers.amoo] block — edit it manually to avoid a duplicate:"
    echo "$block"
    return
  fi
  echo "Would append to $file:"
  echo "$block"
  if [ "$DRY_RUN" -eq 0 ] && confirm "Append this block to $file?"; then
    mkdir -p "$(dirname "$file")"
    needs_separator=0
    [ -s "$file" ] && needs_separator=1
    { [ "$needs_separator" -eq 1 ] && printf '\n'; printf '%s\n' "$block"; } >> "$file"
    echo "done."
  fi
}

install_cursor() {
  local file="$HOME/.cursor/mcp.json"
  if [ ! -d "$HOME/.cursor" ] && ! command -v cursor >/dev/null 2>&1; then
    echo "Cursor not found (no ~/.cursor), skipping."
    return
  fi
  apply_json_client "Cursor" "$file" "amoo"
}

install_windsurf() {
  local file="$HOME/.codeium/windsurf/mcp_config.json"
  if [ ! -d "$HOME/.codeium/windsurf" ]; then
    echo "Windsurf not found (no ~/.codeium/windsurf), skipping."
    return
  fi
  apply_json_client "Windsurf" "$file" "amoo"
}

run_client() {
  case "$1" in
    claude-code) install_claude_code ;;
    claude-desktop) install_claude_desktop ;;
    codex) install_codex ;;
    cursor) install_cursor ;;
    windsurf) install_windsurf ;;
    *) echo "Unknown client: $1" >&2; exit 1 ;;
  esac
}

if [ "$CLIENT" = "all" ]; then
  for c in claude-code claude-desktop codex cursor windsurf; do
    run_client "$c"
  done
elif [ "$CLIENT" = "ask" ]; then
  echo "Detecting installed MCP clients..."
  found=()
  command -v claude >/dev/null 2>&1 && found+=("claude-code")
  [ -d "$HOME/Library/Application Support/Claude" ] && found+=("claude-desktop")
  { command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; } && found+=("codex")
  [ -d "$HOME/.cursor" ] && found+=("cursor")
  [ -d "$HOME/.codeium/windsurf" ] && found+=("windsurf")
  if [ "${#found[@]}" -eq 0 ]; then
    echo "No supported client detected (Claude Code, Claude Desktop, Codex, Cursor, Windsurf)."
    echo "Pass --client explicitly, e.g.: scripts/install-mcp.sh --client claude-code"
    exit 1
  fi
  echo "Found: ${found[*]}"
  for c in "${found[@]}"; do
    run_client "$c"
  done
else
  run_client "$CLIENT"
fi

echo
echo "Restart the client (or reload its MCP connections) to pick up the change."
