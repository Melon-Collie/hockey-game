#!/bin/bash
# Renders the arena bowl offscreen and writes PNGs — the visual check a headless
# GUT run cannot make. Wraps tools/arena_preview.gd; see that file for the shot
# list and what each one frames.
#
#   .claude/hooks/render-arena.sh                     # every shot, into ./.preview
#   .claude/hooks/render-arena.sh coaches,timekeepers # named shots only
#   ARENA_PREVIEW_OUT=/tmp/shots .claude/hooks/render-arena.sh
#
# Godot's own --headless is a DUMMY renderer: it draws nothing and captures
# come back blank. What works without a GPU is a virtual X display plus the
# Compatibility renderer on Mesa's software rasterizer, which is why this runs
# under xvfb-run rather than headless. Expect ~40 s a run, most of it startup.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
POSIX_DIR="$PROJECT_DIR"
if command -v cygpath >/dev/null 2>&1; then
  PROJECT_DIR="$(cygpath -w "$PROJECT_DIR")"
fi

GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
  GODOT="$(command -v godot || true)"
fi
if [ -z "$GODOT" ]; then
  echo "[render-arena] Godot not found. Set GODOT_BIN, or add 'godot' to PATH." >&2
  echo "[render-arena] (web sessions: run .claude/hooks/wait-for-godot.sh first)" >&2
  exit 1
fi

export ARENA_PREVIEW_OUT="${ARENA_PREVIEW_OUT:-$POSIX_DIR/.preview}"
if [ $# -gt 0 ]; then
  export ARENA_PREVIEW_SHOTS="$1"
  shift
fi

# A real window is fine where there's a display (a dev machine); xvfb-run
# supplies one where there isn't (CI, web sessions).
RUNNER=()
if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
  RUNNER=(xvfb-run -a)
fi

exec "${RUNNER[@]}" "$GODOT" --path "$PROJECT_DIR" \
  --rendering-driver opengl3 --rendering-method gl_compatibility \
  --resolution 1280x720 -s res://tools/arena_preview.gd "$@"
