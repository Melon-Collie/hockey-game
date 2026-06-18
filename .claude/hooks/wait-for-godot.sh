#!/bin/bash
# Blocks until the Godot provisioned by the async SessionStart hook is ready,
# then returns. Run this once before the first test run in a Claude Code on the
# web session (see CLAUDE.md > Workflow). No-op once Godot is on PATH.
set -euo pipefail

READY_MARKER="/tmp/.godot-ready"
TIMEOUT_SECS="${1:-600}"
waited=0

godot_ready() { command -v godot >/dev/null 2>&1 && godot --version >/dev/null 2>&1; }

if godot_ready; then
  echo "[wait-for-godot] ready: $(godot --version)"
  exit 0
fi

echo "[wait-for-godot] waiting for the background Godot install..."
while [ "$waited" -lt "$TIMEOUT_SECS" ]; do
  if [ -f "$READY_MARKER" ] && godot_ready; then
    echo "[wait-for-godot] ready after ${waited}s: $(godot --version)"
    exit 0
  fi
  sleep 3
  waited=$((waited + 3))
done

echo "[wait-for-godot] timed out after ${TIMEOUT_SECS}s; Godot not ready." >&2
echo "[wait-for-godot] check the SessionStart hook log for download/install errors." >&2
exit 1
