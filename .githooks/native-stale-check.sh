#!/bin/bash
# Warns when the built GDExtension no longer matches the working tree.
#
# Shared by post-merge and post-checkout. The DLL is built per-machine
# (native/bin/ is gitignored), so a stale binary silently downgrades the changed
# kernels to their GDScript fallback: a mismatched kernel fails its `configure`,
# which is guarded, so nothing errors — the game runs and plays correctly, just
# on the slow path, on the hot path, at 120 Hz. The only other signal is the boot
# log ([native] hot-path kernels: PARTIAL) and the debug digest's native_kernels
# field, both easy to miss. The stale direction doesn't announce itself, which is
# what makes it worse than a build failure.
#
# Compares against native/bin/.built-from — the commit the binary was actually
# built from (stamped by native/SConstruct) — rather than against the range some
# command happened to move. An earlier version diffed ORIG_HEAD..HEAD, which is
# set by merge/pull but NOT by checkout, so switching between two branches whose
# native/src differ warned about nothing at all (#645). What the binary contains
# is a property of the binary, not of how HEAD got here, so ask the binary.
#
# Activated via: git config core.hooksPath .githooks

set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" || exit 0

WATCHED=(native/src native/SConstruct native/build_profile.json
	native/godot-cpp .gitmodules)

# Nothing built on this machine — the GDScript path is the correct answer and
# there is no binary to be stale. Same reason a fresh clone stays quiet.
shopt -s nullglob
built=(native/bin/*.so native/bin/*.dll native/bin/*.dylib)
shopt -u nullglob
[ ${#built[@]} -gt 0 ] || exit 0

# Header on argv, detail lines on stdin — keeps paths intact rather than
# word-splitting a captured list.
warn() {
	echo ""
	echo "[native] $1"
	sed 's/^/[native]   /'
	echo "[native] Rebuild before playing:  bash native/build.sh"
	echo "[native] (Windows: from an MSVC x64 Native Tools prompt, or add use_mingw=yes.)"
	echo ""
}

STAMP_FILE="native/bin/.built-from"
if [ ! -f "$STAMP_FILE" ]; then
	echo "It predates the build stamp, or was built without git available." \
		| warn "A built extension is present but unstamped, so it cannot be checked."
	exit 0
fi

STAMP="$(tr -d '[:space:]' <"$STAMP_FILE")"
if [ -z "$STAMP" ] || ! git cat-file -e "$STAMP^{commit}" 2>/dev/null; then
	echo "Rebased or pruned away — treat the binary as stale." \
		| warn "The extension was built from a commit this repo no longer has."
	exit 0
fi

changed=$(git diff --name-only "$STAMP" HEAD -- "${WATCHED[@]}" 2>/dev/null)
if [ -n "$changed" ]; then
	printf '%s\n' "$changed" \
		| warn "The extension on disk was built from other sources:"
fi
exit 0
