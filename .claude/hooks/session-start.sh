#!/bin/bash
# SessionStart hook: provision a headless Godot so the GUT unit suite can run in
# Claude Code on the web. Runs only in the remote environment; locally the user
# already has Godot installed (pointed at by GODOT_BIN in settings.local.json).
#
# Mirrors the sister projects' dotnet/rust SessionStart hooks: installs
# asynchronously so the session starts immediately, and signals readiness via a
# marker that .claude/hooks/wait-for-godot.sh blocks on before the first test run.
set -euo pipefail

# Async: the session continues while this runs. Anything needing godot must first
# block on the marker via .claude/hooks/wait-for-godot.sh (see CLAUDE.md > Workflow).
echo '{"async": true, "asyncTimeout": 600000}'

READY_MARKER="/tmp/.godot-ready"
rm -f "$READY_MARKER"

# Activate the committed pre-commit gdlint gate (.githooks/pre-commit). Runs in
# both environments; idempotent. This is what enforces "never commit warnings".
git -C "$CLAUDE_PROJECT_DIR" config core.hooksPath .githooks 2>/dev/null || true

# Only run the Godot install in Claude Code on the web; no-op on local.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Match the project's engine version (project.godot config/features = "4.6";
# GDScript build, so the standard — non-mono — Linux export).
GODOT_VERSION="4.6.2-stable"
ZIP="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${ZIP}"
INSTALL="/usr/local/bin/godot"

# Idempotent: a cached container may already have it.
if command -v godot >/dev/null 2>&1 && godot --version 2>/dev/null | grep -q '^4\.6'; then
  echo "[session-start] Godot already present: $(godot --version)"
  touch "$READY_MARKER"
  exit 0
fi

echo "[session-start] Installing Godot ${GODOT_VERSION} (headless)..."
command -v unzip >/dev/null 2>&1 || { apt-get update -o Acquire::Retries=3 || true; apt-get install -y --no-install-recommends unzip || true; }

TMP="$(mktemp -d)"
curl -fsSL --retry 3 -o "$TMP/$ZIP" "$URL"
unzip -q "$TMP/$ZIP" -d "$TMP"
BIN="$(find "$TMP" -name 'Godot_v*_linux.x86_64' -type f | head -1)"
chmod +x "$BIN"
mv "$BIN" "$INSTALL"
rm -rf "$TMP"

# Pre-import resources so the first test run doesn't stall importing assets.
# Tolerate failure — gut_cmdln imports on demand anyway.
godot --headless --path "$CLAUDE_PROJECT_DIR" --import >/dev/null 2>&1 || true

# gdlint (gdtoolkit) for the headless warning pass — see .claude/hooks/run-lint.sh.
echo "[session-start] Installing gdtoolkit (gdlint)..."
pip install -q gdtoolkit 2>/dev/null || pip3 install -q gdtoolkit 2>/dev/null \
  || python3 -m pip install -q gdtoolkit 2>/dev/null || echo "[session-start] gdtoolkit install failed (gdlint unavailable)"

touch "$READY_MARKER"
echo "[session-start] Godot ready: $(godot --version)"
