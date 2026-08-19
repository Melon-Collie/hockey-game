#!/bin/bash
# Renders the SKATER RIG in a set of poses and pixel-diffs them against a saved
# baseline — the articulation check a headless GUT run cannot make. Wraps
# tools/pose_capture.gd; see that file for the pose list and how to read a diff.
#
#   .claude/hooks/render-poses.sh --baseline   # record the baseline first
#   .claude/hooks/render-poses.sh              # render + diff against it
#
# Output paths (user://, never the repo tree) print on save, including a contact
# sheet of every tile.
#
# Godot's own --headless is a DUMMY renderer: it draws nothing and captures come
# back blank. What works without a GPU is a virtual X display plus the
# Compatibility renderer on Mesa's software rasterizer, which is why this runs
# under xvfb-run rather than headless. Same reason as render-arena.sh, and about
# as slow — expect a couple of minutes for the full set.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if command -v cygpath >/dev/null 2>&1; then
  PROJECT_DIR="$(cygpath -w "$PROJECT_DIR")"
fi

GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
  GODOT="$(command -v godot || true)"
fi
if [ -z "$GODOT" ]; then
  echo "[render-poses] Godot not found. Set GODOT_BIN, or add 'godot' to PATH." >&2
  echo "[render-poses] (web sessions: run .claude/hooks/wait-for-godot.sh first)" >&2
  exit 1
fi

# A real window is fine where there's a display (a dev machine); xvfb-run
# supplies one where there isn't (CI, web sessions), and software GL with it.
RUNNER=()
if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
  RUNNER=(xvfb-run -a)
  export LIBGL_ALWAYS_SOFTWARE=1
fi

exec "${RUNNER[@]}" "$GODOT" --path "$PROJECT_DIR" \
  --rendering-driver opengl3 --rendering-method gl_compatibility \
  --audio-driver Dummy -s res://tools/pose_capture.gd -- "$@"
