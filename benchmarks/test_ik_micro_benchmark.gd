extends GutTest

# ── IK GDScript-vs-native micro-benchmark (report-only; NOT in the default
# suite) ─ Times the top/bottom-hand IK solvers in their GDScript reference
# form against the C++ GDExtension ports (native/src/), including the
# boundary-crossing cost of the native calls (solve + get_hand + get_blade is
# three crossings — the honest per-tick price, not just the math).
#
# This is the measurement the GDExtension spike exists to produce: the
# per-call ratio says whether porting hot kernels to C++ pays for itself.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Compare RELATIVELY (GDScript vs native in the same run): a debug build
# inflates GDScript and debug godot-cpp inflates the native side differently.
# Goes pending when the extension isn't built.

const REPS: int = 50000

# Game-default config (mirrors tests/unit/rules/test_top_hand_ik.gd baselines).
const STICK_LENGTH: float = 1.50
const BLADE_Y: float = -0.95
const HAND_REST_Y: float = 0.0
const HAND_Y_MAX: float = 0.30

var _results: Array[Dictionary] = []


func _top_cfg() -> TopHandIK.Config:
	var cfg := TopHandIK.Config.new()
	cfg.stick_length = STICK_LENGTH
	cfg.blade_y = BLADE_Y
	cfg.hand_rest_y = HAND_REST_Y
	cfg.hand_y_max = HAND_Y_MAX
	cfg.rom_forehand_angle_max = PI / 4.0
	cfg.rom_backhand_angle_max = 2.0 * PI / 3.0
	cfg.rom_forehand_reach_max = 0.20
	cfg.rom_backhand_reach_max = 0.70
	return cfg


# Eight targets cycled per iteration — spans CLOSE and FAR regimes plus
# past-ROM clamps so the branch mix resembles real stickhandling rather than
# one perfectly-predicted branch.
func _targets() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.1, -0.3), Vector2(0.0, -1.4), Vector2(-1.2, -1.2),
		Vector2(1.5, -0.8), Vector2(0.4, -0.6), Vector2(-2.5, -0.5),
		Vector2(0.9, -1.8), Vector2(-0.2, -0.9),
	])


func _report(label: String, usec: int) -> void:
	_results.append({"label": label, "us": float(usec) / float(REPS)})


func _print_results() -> void:
	var widest: int = 0
	for r: Dictionary in _results:
		widest = maxi(widest, (r["label"] as String).length())
	gut.p("")
	gut.p("── IK solver cost (µs/call, %d reps) ──" % REPS)
	for r: Dictionary in _results:
		gut.p("  %s  %8.3f" % [(r["label"] as String).rpad(widest), r["us"]])
	gut.p("")


func test_top_hand_gdscript_vs_native() -> void:
	if not ClassDB.class_exists(&"NativeTopHandIK"):
		pending("native extension not built — see native/README.md")
		return
	_results.clear()
	var cfg: TopHandIK.Config = _top_cfg()
	var out := TopHandIK.Result.new()
	var native: RefCounted = ClassDB.instantiate(&"NativeTopHandIK")
	native.stick_length = cfg.stick_length
	native.blade_y = cfg.blade_y
	native.hand_rest_y = cfg.hand_rest_y
	native.hand_y_max = cfg.hand_y_max
	native.rom_forehand_angle_max = cfg.rom_forehand_angle_max
	native.rom_backhand_angle_max = cfg.rom_backhand_angle_max
	native.rom_forehand_reach_max = cfg.rom_forehand_reach_max
	native.rom_backhand_reach_max = cfg.rom_backhand_reach_max

	var shoulder := Vector3(0.22, 0.0, 0.0)
	var targets: PackedVector2Array = _targets()

	# Warm both once (JIT-free either way, but seeds caches/branch predictors
	# equally).
	TopHandIK.solve(shoulder, targets[0], -1.0, cfg, out)
	native.solve(shoulder, targets[0], -1.0)

	var t0: int = Time.get_ticks_usec()
	for i: int in REPS:
		TopHandIK.solve(shoulder, targets[i & 7], -1.0, cfg, out)
	_report("solve         GDScript", Time.get_ticks_usec() - t0)

	t0 = Time.get_ticks_usec()
	for i: int in REPS:
		native.solve(shoulder, targets[i & 7], -1.0)
		var _hand: Vector3 = native.get_hand()
		var _blade: Vector3 = native.get_blade()
	_report("solve         native (3 crossings)", Time.get_ticks_usec() - t0)

	t0 = Time.get_ticks_usec()
	for i: int in REPS:
		var _b: Vector3 = TopHandIK.project_blade(shoulder, targets[i & 7], -1.0, cfg)
	_report("project_blade GDScript", Time.get_ticks_usec() - t0)

	t0 = Time.get_ticks_usec()
	for i: int in REPS:
		var _b: Vector3 = native.project_blade(shoulder, targets[i & 7], -1.0)
	_report("project_blade native (1 crossing)", Time.get_ticks_usec() - t0)

	_print_results()
	var gd_us: float = _results[0]["us"]
	var native_us: float = _results[1]["us"]
	gut.p("  top-hand solve speedup: %.1fx" % (gd_us / native_us))
	assert_true(_results.size() == 4, "benchmark produced rows")


func test_bottom_hand_gdscript_vs_native() -> void:
	if not ClassDB.class_exists(&"NativeBottomHandIK"):
		pending("native extension not built — see native/README.md")
		return
	_results.clear()
	var cfg := BottomHandIK.Config.new()
	cfg.hand_y = -0.35
	cfg.release_angle_max = 1.2
	cfg.release_angle_band = 0.4
	var native: RefCounted = ClassDB.instantiate(&"NativeBottomHandIK")
	native.hand_y = cfg.hand_y
	native.release_angle_max = cfg.release_angle_max
	native.release_angle_band = cfg.release_angle_band

	var shoulder := Vector3(0.22, 0.0, 0.0)
	var grips: PackedVector2Array = _targets()

	var t0: int = Time.get_ticks_usec()
	for i: int in REPS:
		cfg.backhand_angle = float(i & 7) * 0.3
		var _h: Vector3 = BottomHandIK.solve(shoulder, grips[i & 7], cfg)
	_report("bottom-hand GDScript", Time.get_ticks_usec() - t0)

	t0 = Time.get_ticks_usec()
	for i: int in REPS:
		var _h: Vector3 = native.solve(shoulder, grips[i & 7], float(i & 7) * 0.3)
	_report("bottom-hand native (1 crossing)", Time.get_ticks_usec() - t0)

	_print_results()
	var gd_us: float = _results[0]["us"]
	var native_us: float = _results[1]["us"]
	gut.p("  bottom-hand solve speedup: %.1fx" % (gd_us / native_us))
	assert_true(_results.size() == 2, "benchmark produced rows")
