# mitts_native — GDExtension hot-path kernels

C++ ports of per-tick math kernels, registered as `Native*` classes
(`NativeTopHandIK`, `NativeBottomHandIK`). The GDScript originals in
`Scripts/domain/rules/` remain the behavioral reference; each ported kernel is
pinned to its reference by a seeded fuzz test
(`tests/unit/rules/test_native_ik_parity.gd`). **Change a solver in both places
or not at all** — the parity test is the gate.

This directory exists because interpreter overhead on the 120 Hz tick (and its
reconcile-replay amplification) is the game's scripting bottleneck. The rule
for what belongs here: settled, evaluation-grade math with a coarse call
boundary — primitives and vectors in, results out, no callbacks into GDScript
mid-solve. Feel-tunable orchestration stays in GDScript.

## Layout

- `src/` — extension sources. One `.h`/`.cpp` pair per ported kernel plus
  `register_types.*`.
- `godot-cpp/` — git submodule, branch `4.5` (no 4.6 branch exists upstream
  yet; GDExtension is forward-compatible, `compatibility_minimum = "4.5"`).
  Switch to the matching branch when upstream publishes it.
- `build_profile.json` — limits generated bindings to the classes actually
  used; keeps a clean build to ~1–2 min instead of ~10.
- `mitts_native.gdextension` — the manifest Godot auto-loads. Until a binary
  for the current platform exists under `bin/`, Godot logs a load error at
  startup and the `Native*` classes are simply absent — the game and the GUT
  suite still run, and parity/benchmark tests go *pending* instead of failing.
- `bin/` — build output, gitignored. Every machine builds its own.

## Building

First time (or after the submodule bumps):

```bash
git submodule update --init native/godot-cpp
bash native/build.sh              # or: cd native && scons build_profile=build_profile.json -jN
```

`build.sh` builds `template_debug` (what the editor and headless GUT runs
load). Pass `target=template_release` for the export build. On Windows, run
from a shell where either MSVC (`x64 Native Tools` prompt) or MinGW is on
PATH — scons picks up whichever it finds; add `use_mingw=yes` to force MinGW.

After the first successful build, restart the editor once so it picks up the
extension. Subsequent rebuilds hot-reload (`reloadable = true`), though
Windows sometimes holds the DLL lock — if the reload doesn't take, restart the
editor.

## Verifying a port

```bash
bash .claude/hooks/run-gut.sh -gtest=res://tests/unit/rules/test_native_ik_parity.gd
bash .claude/hooks/run-gut.sh -gdir=res://benchmarks   # includes the IK micro-bench
```

The micro-benchmark (`benchmarks/test_ik_micro_benchmark.gd`) reports
GDScript-vs-native µs/call including boundary-crossing cost. Compare
relatively within one run; a debug engine build inflates both sides
differently.

## Adding a kernel

1. Port the rule class to `src/<name>.h/.cpp`, mirroring the GDScript math
   exactly (double scalars, `real_t` vector components — GDScript's precision
   model). Keep the reasoning comments in the GDScript file; the C++ port
   points back at it.
2. Register the class in `register_types.cpp`.
3. Add any newly-referenced engine classes to `build_profile.json`.
4. Add a seeded fuzz parity test beside the existing one, and a
   GDScript-vs-native row to the micro-benchmark.
5. Wire the call site behind a `ClassDB.class_exists` check so unbuilt
   checkouts fall back to the GDScript path.
