extends SceneTree

# Dev visualizer + regression harness: renders the skater rig in a SET OF POSES
# and pixel-diffs the set against a saved baseline.
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/pose_capture.gd -- --baseline     # record
#   ... same without --baseline                          # compare
#
# Locally any GPU works: drop the env var and xvfb-run. Output paths print on
# save (user:// — never the repo tree, so captures can't be committed).
#
# ── Why this exists, and why skater_matrix.gd is not enough ──────────────────
# skater_matrix.gd proves PROPORTIONS and PAINT across five builds. It renders
# one static rest pose, so it says nothing about ARTICULATION — which is the
# only thing a skeleton conversion changes. A byte-identical rest pose would be
# false confidence about the most likely failure. This tool covers the poses the
# rig is actually asked to hold: the gait at two phases and two facings, an arm
# IK reach near its ROM limit, both shot wind-ups, both follow-throughs, the
# block stance, and the lofted blade.
#
# ── Why this file is a two-line bootstrap ───────────────────────────────────
# A `-s` script is COMPILED before the autoloads exist, and compiling it forces
# a compile of every class it names. Naming Skater / SkaterController / PerfProbe
# here would fail those compiles — they reach NetworkManager and friends — and
# the failures are CACHED, so the run dies several frames later with an
# unrelated "Nonexistent function 'new' in base 'GDScript'" inside Skater._ready.
#
# skater_matrix.gd dodges this by going through call()/get() with untyped locals.
# That works, but it costs the type annotations this project requires everywhere,
# and this tool is far larger than that one. Loading the real work from a second
# script AFTER the tree is up compiles it at a point where every identifier
# resolves, so pose_capture_runner.gd is written in ordinary typed GDScript.
const RUNNER: String = "res://tools/pose_capture_runner.gd"
const TILE: int = 384

var _started: bool = false


func _init() -> void:
	DisplayServer.window_set_size(Vector2i(TILE, TILE))
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _started:
		return
	_started = true
	var runner: Node = (load(RUNNER) as GDScript).new() as Node
	root.add_child(runner)
	runner.call("begin", OS.get_cmdline_user_args().has("--baseline"))
