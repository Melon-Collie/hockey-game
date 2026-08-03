#!/bin/bash
# Builds the mitts_native GDExtension (see native/README.md).
# Extra args pass through to scons, e.g.: bash native/build.sh target=template_release
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$NATIVE_DIR/godot-cpp/SConstruct" ]; then
  echo "[build] godot-cpp submodule missing — fetching..." >&2
  git -C "$NATIVE_DIR/.." submodule update --init native/godot-cpp
fi

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
cd "$NATIVE_DIR"
exec scons build_profile=build_profile.json -j"$JOBS" "$@"
