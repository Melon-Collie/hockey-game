#!/bin/bash
# Runs the GUT unit suite headless. Works both on the user's local machine and
# in Claude Code on the web.
#
#   Local: set GODOT_BIN to the Godot executable (see .claude/settings.local.json).
#   Web:   the SessionStart hook installs `godot` onto PATH; run
#          .claude/hooks/wait-for-godot.sh first so the async install has finished.
#
# Extra args pass straight through to gut_cmdln, e.g.:
#   .claude/hooks/run-gut.sh -gtest=res://tests/unit/rules/test_shot_release_rules.gd
#   .claude/hooks/run-gut.sh -gdir=res://tests/unit/state
# With no args it runs everything in .gutconfig.json (all of res://tests/).
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# On Windows/MSYS the Godot binary is a native .exe, so it needs a Windows-style
# path; passing the MSYS '/c/...' form makes it miss the import cache and
# re-import everything (slow). cygpath is a no-op on Linux (web sessions).
if command -v cygpath >/dev/null 2>&1; then
  PROJECT_DIR="$(cygpath -w "$PROJECT_DIR")"
fi

GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
  GODOT="$(command -v godot || true)"
fi
if [ -z "$GODOT" ]; then
  echo "[run-gut] Godot not found. Set GODOT_BIN, or add 'godot' to PATH." >&2
  echo "[run-gut] (web sessions: run .claude/hooks/wait-for-godot.sh first)" >&2
  exit 1
fi

exec "$GODOT" --headless --path "$PROJECT_DIR" \
  -s res://addons/gut/gut_cmdln.gd "$@"
