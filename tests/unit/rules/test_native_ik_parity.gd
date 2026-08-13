extends GutTest

# Parity fuzz: the C++ GDExtension IK solvers (NativeTopHandIK /
# NativeBottomHandIK, native/src/) against their GDScript references
# (TopHandIK / BottomHandIK). Seeded RNG, wide config/input ranges covering
# both regimes, ROM clamps, and the hand_y_max overshoot path.
#
# When the extension isn't built (fresh clone, CI without a native build),
# every test goes pending rather than failing — run native/build.sh to build.
#
# Tolerance: the ports intentionally match GDScript's precision model (double
# scalars, real_t vector components), so disagreement is float-roundoff-scale.
# 1e-3 meters is far below anything gameplay-visible and far above roundoff;
# a real logic divergence produces errors orders of magnitude larger.

const TOLERANCE: float = 0.001
const FUZZ_ITERATIONS: int = 2000
const SEED: int = 0x4D495454  # "MITT" — fixed so failures reproduce.

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = SEED


func _native_missing() -> bool:
	if ClassDB.class_exists(&"NativeTopHandIK"):
		return false
	NativeParityGuard.report_missing(self, "NativeTopHandIK")
	return true


func _random_top_cfg() -> TopHandIK.Config:
	var cfg := TopHandIK.Config.new()
	cfg.stick_length = _rng.randf_range(1.0, 2.0)
	cfg.blade_y = _rng.randf_range(-1.2, -0.6)
	cfg.hand_rest_y = _rng.randf_range(-0.2, 0.2)
	cfg.hand_y_max = cfg.hand_rest_y + _rng.randf_range(0.05, 0.6)
	cfg.rom_forehand_angle_max = _rng.randf_range(0.1, 1.2)
	cfg.rom_backhand_angle_max = _rng.randf_range(0.1, 2.5)
	cfg.rom_forehand_reach_max = _rng.randf_range(0.05, 0.5)
	cfg.rom_backhand_reach_max = _rng.randf_range(0.05, 1.0)
	# The boards' reach cap. Mostly unconstrained (open ice), but a third of the
	# cases bind it across the CLOSE/FAR boundary so the capped regime split is
	# fuzzed on both sides.
	cfg.max_blade_reach = INF if _rng.randf() < 0.67 else _rng.randf_range(0.2, 2.0)
	return cfg


func _native_top_from(cfg: TopHandIK.Config) -> RefCounted:
	var native: RefCounted = ClassDB.instantiate(&"NativeTopHandIK")
	native.stick_length = cfg.stick_length
	native.blade_y = cfg.blade_y
	native.hand_rest_y = cfg.hand_rest_y
	native.hand_y_max = cfg.hand_y_max
	native.rom_forehand_angle_max = cfg.rom_forehand_angle_max
	native.rom_backhand_angle_max = cfg.rom_backhand_angle_max
	native.rom_forehand_reach_max = cfg.rom_forehand_reach_max
	native.rom_backhand_reach_max = cfg.rom_backhand_reach_max
	native.max_blade_reach = cfg.max_blade_reach
	return native


func _random_shoulder() -> Vector3:
	return Vector3(_rng.randf_range(-0.4, 0.4), 0.0, _rng.randf_range(-0.4, 0.4))


func _random_target() -> Vector2:
	# Radii 0..5 m sweep CLOSE, FAR, and past-ROM; a bias toward small radii
	# keeps the CLOSE regime (and its hand_y_max clamp) well represented.
	var angle: float = _rng.randf_range(-PI, PI)
	var dist: float = _rng.randf_range(0.0, 5.0)
	if _rng.randf() < 0.4:
		dist = _rng.randf_range(0.0, 1.2)
	return Vector2(sin(angle) * dist, -cos(angle) * dist)


func test_top_hand_project_blade_matches_native() -> void:
	if _native_missing():
		return
	for i: int in FUZZ_ITERATIONS:
		var cfg: TopHandIK.Config = _random_top_cfg()
		var native: RefCounted = _native_top_from(cfg)
		var shoulder: Vector3 = _random_shoulder()
		var target: Vector2 = _random_target()
		var sign_val: float = -1.0 if _rng.randf() < 0.5 else 1.0

		var gd: Vector3 = TopHandIK.project_blade(shoulder, target, sign_val, cfg)
		var cpp: Vector3 = native.project_blade(shoulder, target, sign_val)
		var err: float = gd.distance_to(cpp)
		if err > TOLERANCE:
			fail_test("project_blade diverged at iter %d: gd=%s cpp=%s err=%f target=%s sign=%.0f" % [
					i, gd, cpp, err, target, sign_val])
			return
	pass_test("%d project_blade fuzz cases within %f" % [FUZZ_ITERATIONS, TOLERANCE])


func test_top_hand_solve_matches_native() -> void:
	if _native_missing():
		return
	var out := TopHandIK.Result.new()
	for i: int in FUZZ_ITERATIONS:
		var cfg: TopHandIK.Config = _random_top_cfg()
		var native: RefCounted = _native_top_from(cfg)
		var shoulder: Vector3 = _random_shoulder()
		var target: Vector2 = _random_target()
		var sign_val: float = -1.0 if _rng.randf() < 0.5 else 1.0

		TopHandIK.solve(shoulder, target, sign_val, cfg, out)
		native.solve(shoulder, target, sign_val)
		var hand_err: float = out.hand.distance_to(native.get_hand())
		var blade_err: float = out.blade.distance_to(native.get_blade())
		if hand_err > TOLERANCE or blade_err > TOLERANCE:
			fail_test("solve diverged at iter %d: hand_err=%f blade_err=%f target=%s sign=%.0f" % [
					i, hand_err, blade_err, target, sign_val])
			return
	pass_test("%d solve fuzz cases within %f" % [FUZZ_ITERATIONS, TOLERANCE])


func test_bottom_hand_solve_matches_native() -> void:
	if _native_missing():
		return
	var native: RefCounted = ClassDB.instantiate(&"NativeBottomHandIK")
	for i: int in FUZZ_ITERATIONS:
		var cfg := BottomHandIK.Config.new()
		cfg.hand_y = _rng.randf_range(-0.6, 0.2)
		cfg.backhand_angle = _rng.randf_range(0.0, PI)
		cfg.release_angle_max = _rng.randf_range(0.2, 2.0)
		cfg.release_angle_band = _rng.randf_range(0.01, 1.0)
		var shoulder: Vector3 = _random_shoulder()
		var grip := Vector2(_rng.randf_range(-1.5, 1.5), _rng.randf_range(-1.5, 1.5))

		var gd: Vector3 = BottomHandIK.solve(shoulder, grip, cfg)
		native.hand_y = cfg.hand_y
		native.release_angle_max = cfg.release_angle_max
		native.release_angle_band = cfg.release_angle_band
		var cpp: Vector3 = native.solve(shoulder, grip, cfg.backhand_angle)
		var err: float = gd.distance_to(cpp)
		if err > TOLERANCE:
			fail_test("bottom-hand diverged at iter %d: gd=%s cpp=%s err=%f angle=%f" % [
					i, gd, cpp, err, cfg.backhand_angle])
			return
	pass_test("%d bottom-hand fuzz cases within %f" % [FUZZ_ITERATIONS, TOLERANCE])
