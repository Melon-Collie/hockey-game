# mitts_native — GDExtension hot-path kernels

C++ ports of per-tick math kernels, registered as `Native*` classes
(`NativeTopHandIK`, `NativeBottomHandIK`, `NativeSkaterGait`,
`NativeSkaterMovement`, `NativePuckStep`, `NativeBladeDangle`). The GDScript
originals (in `Scripts/domain/rules/` and `Scripts/controllers/`) remain the
behavioral reference; each ported kernel is pinned to its reference by a
seeded fuzz test (`tests/unit/rules/test_native_ik_parity.gd`,
`test_native_gait_parity.gd`). **Change a solver in both places or not at
all** — the parity tests are the gate. `NativeSkaterGait` additionally loads
its ~126 tunables from the controller's @exports by name via
`configure(controller)`; renaming an export fails the configure parity test
rather than silently desyncing.

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

## Wired call sites

Every port is live behind a null-checked native handle created where its
GDScript config is built — the extension missing simply leaves the handle
null and the reference GDScript path runs (fresh clones, CI, and any platform
without a built binary lose performance, never correctness):

- **Gait** — inside `SkaterSkatingCoordinator` (`_apply_native`): all five
  `apply()` call sites route through the coordinator, which republishes the
  public channels (`stride_phase`, yaw offsets, trunk adds) so external
  readers see a truthful surface. Reconfigured from
  `SkaterController.apply_attributes` via `native_reconfigure()`.
- **Movement** — `SkaterController._apply_movement` / `_apply_block_movement`
  (per-tick thrust rides `apply_movement_with_thrust`), plus the batched
  `integrate_forward` in `RemoteController` (stage-3 render) and
  `LagCompRewind.forward_predict_skater` (host claim rewind) — both through
  the SAME per-skater instance (`SkaterController.native_movement()`), which
  is what keeps render == rewind.
- **Blade IK** — `SkaterIKCoordinator` (`project_blade`, the 3-pass
  `_solve_top_hand`, `update_bottom_hand`); config syncs inside the cached-
  config builders, so `invalidate_configs()` covers both representations.
- **Blade dangle** — `SkaterIKCoordinator.apply_blade_from_mouse` step 2 (the
  stateful speed-cap / arrive-law smoother, `NativeBladeDangle.advance`);
  reset/seed forward from `reset_blade_smoothing` / `seed_blade_smoothing`,
  config syncs via `_sync_dangle_config` under `invalidate_configs()`.
- **Puck step** — host drive (`Puck._drive_analytic`, per sub-step so the
  goalie interleave keeps its exact order) and client prediction
  (`PuckController._run_prediction`, whole-tick `step_tick` batching), both
  configured by `NativePuckStepFactory` so authority and prediction run the
  identical step.
- **Swept-OBB atom** — `GoalieContactDetector.nearest` (host saves + client
  goalie-stop prediction).

The parity suites force the GDScript path on their reference objects (e.g.
nulling `_skating._native`) — a parity test must never compare the native
port against itself.

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
