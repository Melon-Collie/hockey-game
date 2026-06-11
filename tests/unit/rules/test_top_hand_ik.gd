extends GutTest

# TopHandIK — 1-bone inverse kinematics for the stick's top hand. Given a
# desired blade target in upper-body-local XZ space, the solver returns
# (hand, blade) respecting fixed stick length and an asymmetric ROM.
#
# Two regimes:
#   FAR   (target ≥ stick_horiz_at_rest): hand stays at hand_rest_y, displaces
#         in XZ toward target up to ROM; blade sits stick_horiz_at_rest from
#         clamped hand along the aim line.
#   CLOSE (target < stick_horiz_at_rest): hand XZ stays at shoulder, hand Y
#         rises so the stick tilts vertical and blade lands on target.
#         Clamped by hand_y_max; overshoots along aim line when clamped.

# Baselines chosen to match current game defaults.
const STICK_LENGTH: float = 1.50
const BLADE_Y: float = -0.95
const HAND_REST_Y: float = 0.0
const HAND_Y_MAX: float = 0.30
const SHOULDER_OFFSET: float = 0.22
# Derived horizontal stick projection at rest: sqrt(1.50² − 0.95²) ≈ 1.1608.
const STICK_HORIZ_AT_REST: float = 1.16081
# Derived horizontal stick projection at hand_y_max: sqrt(1.50² − 1.25²).
const STICK_HORIZ_AT_MAX: float = 0.82916

# ROM
const FORE_ANGLE: float = PI / 4.0        # 45°
const BACK_ANGLE: float = 2.0 * PI / 3.0  # 120°
const FORE_REACH: float = 0.20
const BACK_REACH: float = 0.70

func _cfg() -> TopHandIK.Config:
	var cfg := TopHandIK.Config.new()
	cfg.stick_length = STICK_LENGTH
	cfg.blade_y = BLADE_Y
	cfg.hand_rest_y = HAND_REST_Y
	cfg.hand_y_max = HAND_Y_MAX
	cfg.rom_forehand_angle_max = FORE_ANGLE
	cfg.rom_backhand_angle_max = BACK_ANGLE
	cfg.rom_forehand_reach_max = FORE_REACH
	cfg.rom_backhand_reach_max = BACK_REACH
	return cfg

# A left-handed skater has blade on −X and shoulder (top hand) on +X.
func _lefty_shoulder() -> Vector3:
	return Vector3(SHOULDER_OFFSET, 0.0, 0.0)

# A right-handed skater has blade on +X and shoulder (top hand) on −X.
func _righty_shoulder() -> Vector3:
	return Vector3(-SHOULDER_OFFSET, 0.0, 0.0)

# ── Invariant: 3D stick length is constant ───────────────────────────────

func test_stick_length_3d_is_constant_for_all_targets() -> void:
	# Whatever the solver returns, |blade − hand| in 3D must equal stick_length
	# (the rigid rod invariant). Horizontal projection varies with hand Y; full
	# 3D length does not.
	var shoulder: Vector3 = _lefty_shoulder()
	for deg: int in range(-180, 180, 15):
		for dist: float in [0.0, 0.2, 0.8, 1.16, 1.5, 2.5, 5.0]:
			var angle: float = deg_to_rad(deg)
			var target := Vector2(sin(angle) * dist, -cos(angle) * dist)
			var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
			var length_3d: float = result.hand.distance_to(result.blade)
			assert_almost_eq(
				length_3d, STICK_LENGTH, 0.001,
				"stick length violated at deg=%d dist=%.2f" % [deg, dist])

# ── Blade Y is always locked; hand Y never exceeds ceiling ───────────────

func test_blade_y_locked_and_hand_y_within_bounds() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	for target: Vector2 in [
			Vector2(0.0, 0.0),         # at shoulder (close, hand_y clamps)
			Vector2(0.5, -0.5),        # intermediate
			Vector2(-1.5, -1.5),       # far forehand
			Vector2(1.5, -1.2),        # far backhand
		]:
		var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
		assert_almost_eq(result.blade.y, BLADE_Y, 0.0001, "blade Y locked")
		assert_true(
				result.hand.y >= HAND_REST_Y - 0.0001 and result.hand.y <= HAND_Y_MAX + 0.0001,
				"hand Y in [%.3f, %.3f] for target %s — got %.3f" % [HAND_REST_Y, HAND_Y_MAX, target, result.hand.y])

# ── FAR regime: target past stick range ──────────────────────────────────

func test_far_target_on_stick_sphere_hits_target_exactly() -> void:
	# Target exactly at stick_horiz_at_rest from shoulder, dead ahead.
	# Boundary between FAR and CLOSE regimes — should resolve via FAR branch
	# (or CLOSE with hand_y at rest); either way blade lands on target.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x, shoulder.z - STICK_HORIZ_AT_REST)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.blade.x, target.x, 0.001, "blade X == target X")
	assert_almost_eq(result.blade.z, target.y, 0.001, "blade Z == target Z")
	assert_almost_eq(result.hand.y, HAND_REST_Y, 0.001, "hand at rest Y at boundary")

func test_far_target_slightly_past_stick_reachable_by_small_hand_extension() -> void:
	# Backhand side, just past stick_horiz_at_rest but within backhand ROM.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x + STICK_HORIZ_AT_REST + 0.15, shoulder.z - 0.2)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.blade.x, target.x, 0.001, "reachable backhand: blade on target X")
	assert_almost_eq(result.blade.z, target.y, 0.001, "reachable backhand: blade on target Z")
	assert_almost_eq(result.hand.y, HAND_REST_Y, 0.001, "hand at rest Y in FAR regime")

func test_far_forehand_target_past_rom_clamps_hand_short() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x - 4.0, shoulder.z - 0.1)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())

	var hand_disp := Vector2(
			result.hand.x - shoulder.x, result.hand.z - shoulder.z).length()
	assert_almost_eq(
			hand_disp, FORE_REACH, 0.001,
			"hand clamped to rom_forehand_reach_max on forehand side")

	var blade_xz := Vector2(result.blade.x, result.blade.z)
	assert_gt(
			blade_xz.distance_to(target), 0.1,
			"blade falls short of unreachable forehand target")

func test_far_backhand_hand_extends_to_backhand_reach_max() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x + 5.0, shoulder.z - 0.1)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	var hand_disp := Vector2(
			result.hand.x - shoulder.x, result.hand.z - shoulder.z).length()
	assert_almost_eq(
			hand_disp, BACK_REACH, 0.001,
			"hand clamped to rom_backhand_reach_max on backhand side")

func test_far_backhand_target_reaches_farther_than_forehand() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var d: float = STICK_HORIZ_AT_REST + 0.50

	var fore_target := Vector2(shoulder.x - d, shoulder.z)
	var fore_result: Dictionary = TopHandIK.solve(shoulder, fore_target, -1.0, _cfg())
	var fore_blade := Vector2(fore_result.blade.x, fore_result.blade.z)
	var fore_reach_achieved: float = shoulder.distance_to(
			Vector3(fore_blade.x, shoulder.y, fore_blade.y))

	var back_target := Vector2(shoulder.x + d, shoulder.z)
	var back_result: Dictionary = TopHandIK.solve(shoulder, back_target, -1.0, _cfg())
	var back_blade := Vector2(back_result.blade.x, back_result.blade.z)
	var back_reach_achieved: float = shoulder.distance_to(
			Vector3(back_blade.x, shoulder.y, back_blade.y))

	assert_gt(
			back_reach_achieved, fore_reach_achieved + 0.1,
			"backhand blade reaches meaningfully farther than forehand at same target distance")

# ── CLOSE regime: target inside stick reach ──────────────────────────────

func test_close_target_hits_blade_exactly_via_hand_rise() -> void:
	# Target well inside stick_horiz_at_rest. Hand should rise to make the
	# horizontal stick projection match r exactly; blade lands on target.
	var shoulder: Vector3 = _lefty_shoulder()
	# Pick a distance where hand_y doesn't clamp: need ideal_hand_y ≤ hand_y_max.
	# ideal_hand_y = blade_y + sqrt(stick² − r²). We want r such that
	# sqrt(1.5² − r²) ≤ blade_y + hand_y_max + 0.95 = 1.25 → r ≥ sqrt(1.5² − 1.25²)
	# ≈ 0.829. Pick r = 0.9, which is < stick_horiz_at_rest (1.16).
	var target := Vector2(shoulder.x, shoulder.z - 0.9)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.blade.x, target.x, 0.001, "blade X lands on target")
	assert_almost_eq(result.blade.z, target.y, 0.001, "blade Z lands on target")
	assert_gt(result.hand.y, HAND_REST_Y + 0.0001, "hand rose above rest")
	assert_lt(result.hand.y, HAND_Y_MAX - 0.0001, "hand not clamped at max")

func test_close_target_stays_at_shoulder_xz() -> void:
	# CLOSE regime: hand XZ stays at shoulder; only Y rises.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x + 0.3, shoulder.z - 0.5)  # ~0.58 from shoulder
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.hand.x, shoulder.x, 0.001, "hand X at shoulder in CLOSE regime")
	assert_almost_eq(result.hand.z, shoulder.z, 0.001, "hand Z at shoulder in CLOSE regime")

func test_close_target_at_shoulder_clamps_hand_and_overshoots_along_aim() -> void:
	# Target at (or right on top of) the shoulder: the solver would want the
	# hand to rise all the way to blade_y + stick_length = 0.55 m so the stick
	# is vertical. But hand_y_max = 0.30 clamps it; stick_horiz can't go below
	# STICK_HORIZ_AT_MAX ≈ 0.829. So the blade can't come in closer than that
	# to the shoulder. With aim_dir falling back to (0, −1), blade lands at
	# shoulder + (0, -1) × STICK_HORIZ_AT_MAX.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x, shoulder.z)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.hand.y, HAND_Y_MAX, 0.001, "hand clamped at hand_y_max")
	assert_almost_eq(result.blade.x, shoulder.x, 0.001, "blade on forward axis")
	assert_almost_eq(result.blade.z, shoulder.z - STICK_HORIZ_AT_MAX, 0.001, "blade at min horizontal reach along forward")

func test_close_to_far_continuity_at_stick_horiz_at_rest() -> void:
	# At the exact boundary r == stick_horiz_at_rest, the two regimes should
	# agree: hand at hand_rest_y, blade on target. Tested by sampling both
	# just below and just above the boundary and checking continuity of hand Y.
	var shoulder: Vector3 = _lefty_shoulder()
	var forward := Vector2(0.0, -1.0)

	var just_below_target := shoulder_xz_from(shoulder) + forward * (STICK_HORIZ_AT_REST - 0.0005)
	var just_above_target := shoulder_xz_from(shoulder) + forward * (STICK_HORIZ_AT_REST + 0.0005)

	var below: Dictionary = TopHandIK.solve(shoulder, just_below_target, -1.0, _cfg())
	var above: Dictionary = TopHandIK.solve(shoulder, just_above_target, -1.0, _cfg())

	# Hand Y should be nearly identical across the boundary — the CLOSE branch's
	# ideal_hand_y converges to hand_rest_y as r → stick_horiz_at_rest.
	assert_almost_eq(
			below.hand.y, above.hand.y, 0.002,
			"hand Y continuous across FAR/CLOSE boundary")
	# Also: blade should be the same in both regimes at this r.
	assert_almost_eq(
			below.blade.x, above.blade.x, 0.002,
			"blade X continuous across FAR/CLOSE boundary")
	assert_almost_eq(
			below.blade.z, above.blade.z, 0.002,
			"blade Z continuous across FAR/CLOSE boundary")

func shoulder_xz_from(shoulder: Vector3) -> Vector2:
	return Vector2(shoulder.x, shoulder.z)

# ── Handedness mirror ─────────────────────────────────────────────────────

func test_righty_mirrors_lefty_in_x() -> void:
	var lefty_shoulder: Vector3 = _lefty_shoulder()
	var righty_shoulder: Vector3 = _righty_shoulder()
	var lefty_target := Vector2(-1.5, -1.2)
	var righty_target := Vector2(1.5, -1.2)

	var lefty: Dictionary = TopHandIK.solve(lefty_shoulder, lefty_target, -1.0, _cfg())
	var righty: Dictionary = TopHandIK.solve(righty_shoulder, righty_target, 1.0, _cfg())

	assert_almost_eq(lefty.hand.x, -righty.hand.x, 0.001, "hand X mirrors")
	assert_almost_eq(lefty.hand.y, righty.hand.y, 0.001, "hand Y matches")
	assert_almost_eq(lefty.hand.z, righty.hand.z, 0.001, "hand Z matches")
	assert_almost_eq(lefty.blade.x, -righty.blade.x, 0.001, "blade X mirrors")
	assert_almost_eq(lefty.blade.z, righty.blade.z, 0.001, "blade Z matches")
