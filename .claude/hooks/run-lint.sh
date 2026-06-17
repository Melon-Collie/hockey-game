#!/bin/bash
# gdlint the project (or specific files) via gdtoolkit, honoring .gdlintrc.
# Catches the headless, cross-environment subset of warnings Godot's editor
# shows — dead code, mistakes, whitespace hygiene — that `godot --headless`
# cannot surface. (Godot-engine-specific warnings like SHADOWED_VARIABLE_BASE_CLASS
# / INT_AS_ENUM still only appear in the editor.)
#
#   .claude/hooks/run-lint.sh                  # lint Scripts/ + tests/
#   .claude/hooks/run-lint.sh Scripts/foo.gd   # lint specific files
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$PROJECT_DIR"

if ! python -m gdtoolkit.linter --version >/dev/null 2>&1; then
  echo "[run-lint] gdtoolkit not installed. Run: pip install gdtoolkit" >&2
  echo "[run-lint] (web sessions get it from the SessionStart hook)" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  exec python -m gdtoolkit.linter "$@"
fi
exec python -m gdtoolkit.linter Scripts/ tests/
