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
# Keep the POSIX form for local filesystem work (find/cache mtime below); the
# cygpath'd form is only for handing paths to the native Godot .exe.
POSIX_DIR="$PROJECT_DIR"

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

# Rebuild the global class cache when it's stale. Headless runs read
# .godot/global_script_class_cache.cfg instead of rescanning the tree, so a
# `class_name` added since the cache was last built resolves as "not declared"
# and cascades into false failures (game-layer autoloads fail to compile, taking
# their dependents' tests down with them). Two ways the cache goes stale: a
# reused web container carrying a cache older than the checkout (session-start's
# import runs only on a fresh Godot install, not the already-present path), or a
# new class_name added mid-session. A `find` for any *.gd newer than the cache is
# cheap on the common (fresh-cache) path; the editor import runs only when
# something actually changed. CI does its own --import, so it never hits this.
#
# tests/ is scanned as well as Scripts/, because a `class_name` declared by a
# test helper goes stale exactly the same way — and fails worse. An unresolved
# class is a PARSE error, and GUT skips a file it cannot parse with a warning
# rather than a failure, so the suite stays green while the tests in that file
# simply stop running.
CACHE="$POSIX_DIR/.godot/global_script_class_cache.cfg"
if [ ! -f "$CACHE" ] \
    || [ -n "$(find "$POSIX_DIR/Scripts" "$POSIX_DIR/tests" -name '*.gd' -newer "$CACHE" -print -quit 2>/dev/null)" ]; then
  echo "[run-gut] class cache stale — reimporting (one-time per script change)..." >&2
  "$GODOT" --headless --path "$PROJECT_DIR" --import --quit >/dev/null 2>&1 || true
fi

exec "$GODOT" --headless --path "$PROJECT_DIR" \
  -s res://addons/gut/gut_cmdln.gd "$@"
